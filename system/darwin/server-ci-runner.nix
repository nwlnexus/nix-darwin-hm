# Native, ephemeral, just-in-time macOS GitHub Actions runner for server Macs (d.server.ciRunner; olympus-sdk #694,
# decision H20). One job at a time, as a dedicated unprivileged hidden user, registered per job through the
# `olympus-arc` GitHub App. The loop is scripts/server/ci-runner-loop.sh, run as root by a LaunchDaemon:
# credentials stay root-only, the runner user only ever sees the one-job JIT config, in its environment.
#
# Why not nix-darwin's own services.github-runners: it registers a long-lived runner with a registration token or a
# PAT, one runner for many jobs. Ephemeral JIT with an App key and a wiped home per job is a different shape.
#
# The runner binary is the official actions/runner osx-arm64 release (pinned version and hash, fetched by nix; the
# nixpkgs github-runner builds the .NET runner from source, which is slow, large and has no darwin cache hit).
# Bump: take the new tag from https://github.com/actions/runner/releases, set `version`, and put
# `nix store prefetch-file --unpack --json <url>` in `hash`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.server.ciRunner;
  server = config.d.server;
  primary = config.system.primaryUser;

  runner =
    let
      version = "2.338.2";
    in
    pkgs.fetchzip {
      name = "actions-runner-osx-arm64-${version}";
      url = "https://github.com/actions/runner/releases/download/v${version}/actions-runner-osx-arm64-${version}.tar.gz";
      hash = "sha256-qlkL1OZlUVjg8y+tjmqoajCd0ayPYMoD4wSupy9gBn0=";
      stripRoot = false;
    };

  loop = pkgs.writeScript "ci-runner-loop" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ../../scripts/server/ci-runner-loop.sh}
  '';

  heartbeat = pkgs.writeScript "ci-runner-heartbeat" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ../../scripts/server/ci-runner-heartbeat.sh}
  '';
  hb = cfg.heartbeat;
  hbLog = "/var/log/ci-runner-heartbeat.log";

  # The runner user's uid and gid: the range nix-darwin's own runner module uses for its service account.
  id = 533;
  dedicated = cfg.user != "root" && cfg.user != primary;

  logFile = "/var/log/ci-runner.log";
  net = cfg.networkIsolation;

  # pf rules for the runner user (olympus-sdk #394 F4), loaded by the loop into a child of Apple's com.apple anchor
  # before every registration. pf matches `user` on TCP and UDP sockets the user owns; `block return` makes a blocked
  # connect fail at once (RST / ICMP unreachable) instead of hanging the job. First match wins (`quick`).
  # Name resolution normally goes through mDNSResponder (its own user, so not matched here); tools with their own
  # resolver send DNS as the runner user, hence the pass for the configured resolvers.
  pfText = (
    let
      u = cfg.user;
      list = xs: "{ ${lib.concatStringsSep " " xs} }";
    in
    lib.concatStringsSep "\n" (
      [ "# Managed by nix-darwin (d.server.ciRunner.networkIsolation). Loaded by io.olympus.ci-runner." ]
      # <ci_dns>: dnsResolvers plus the IPv4 nameservers of /etc/resolv.conf, added by the loop at load time (DHCP
      # decides them; nothing site-specific is written here).
      ++ [
        (
          "table <ci_dns> persist" + lib.optionalString (net.dnsResolvers != [ ]) " ${list net.dnsResolvers}"
        )
        "pass out quick proto { udp tcp } from any to <ci_dns> port 53 user ${u} keep state"
      ]
      ++ map (
        a: "pass out quick proto tcp from any to ${a.address} port ${toString a.port} user ${u} keep state"
      ) net.allowedDestinations
      ++ [
        # Loopback carries every local listener (sshd, SMB, Screen Sharing, kdc, the VM's forwarded ssh, and the
        # host's own LAN, tailnet and global IPv6 addresses). Only the ephemeral range stays open, for the job's own
        # test servers on port 0.
        "block return out quick on lo0 proto { tcp udp } from any to any port < ${toString net.loopbackMinPort} user ${u}"
        "block return out quick inet proto { tcp udp } from any to ${list net.blockedIPv4} user ${u}"
      ]
      ++ (
        if net.blockIPv6 then
          # Everything but ::1 (above loopbackMinPort, like 127.0.0.1: a test server on `localhost`).
          [
            "pass out quick on lo0 inet6 proto { tcp udp } from any to ::1 user ${u} keep state"
            "block return out quick inet6 proto { tcp udp } from any to any user ${u}"
          ]
        else
          # The LAN hands out global IPv6 addresses, so ULA/link-local alone would leave every LAN host reachable.
          # <ci_lan6> holds this site's own global prefixes (the /56 around each global address of the host), filled
          # by the loop at load time because the ISP assigns them (nothing site-specific is written here); public
          # IPv6 stays open (the 1Password Connect host answers on IPv6 and Go clients do not fall back).
          [
            "table <ci_lan6> persist"
            "block return out quick inet6 proto { tcp udp } from any to <ci_lan6> user ${u}"
            "block return out quick inet6 proto { tcp udp } from any to ${list net.blockedIPv6} user ${u}"
          ]
      )
      ++ [ "" ]
    )
  );
  pfRules = pkgs.writeText "ci-runner.pf.conf" pfText;
in
{
  options.d.server.ciRunner = {
    enable = lib.mkEnableOption "the native ephemeral just-in-time macOS GitHub Actions runner (needs d.server.enable)";
    org = lib.mkOption {
      type = lib.types.str;
      default = "nwlnexus";
      description = "The GitHub organization the runners register in.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "olympus-ci";
      description = ''
        The organization runner group, by name; its id is looked up on every registration. Per host: a release-only
        Mac (olympus-sdk #394 F1b) registers in a separate group restricted to the release workflow, with its own
        label, e.g. `group = "olympus-release"; labels = [ "self-hosted" "macOS" "ARM64" "macos-release" ];`.
      '';
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "self-hosted"
        "macOS"
        "ARM64"
        "macos-arm64"
      ];
      description = "The runner's labels.";
    };
    appIdFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/root/ci-runner/app-id";
      description = "Root-only file holding the GitHub App id. The owner installs it; it is not in this repo.";
    };
    installationIdFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/root/ci-runner/installation-id";
      description = "Root-only file holding the App's installation id.";
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/root/ci-runner/private-key.pem";
      description = "Root-only file holding the App's private key (PEM). The runner user can never read it.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "_ghrunner";
      description = "The unprivileged, hidden user the jobs run as. Not an admin, not in sudoers.";
    };
    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ci-runner";
      description = "Holds the runner user's home (home/), a fresh copy of the runner (runner/) and its _work. Wiped after every job.";
    };
    nice = lib.mkOption {
      type = lib.types.ints.between 0 19;
      default = 10;
      description = "nice(1) value for the job, so it yields to the VM and the system daemons.";
    };
    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/db/ci-runner/state";
      description = ''
        Root-only file where the loop records its last wipe result and last registration time (key=value lines, no
        secrets), read by the heartbeat. Must live outside workDir, which is wiped.
      '';
    };
    heartbeat = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Push health gauges for this runner to an OpenTelemetry collector over OTLP/HTTP JSON from a root
          LaunchDaemon (olympus-sdk #392): ci_runner_daemon_up, ci_runner_runner_up,
          ci_runner_last_registration_timestamp_seconds and ci_runner_last_wipe_ok, with resource attributes
          service.name=ci-runner and host.name=<LocalHostName>. The cluster alerts on them (olympus-gitops,
          rule group ci-runners-macos).
        '';
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "http://obs-otlp.raptor-mimosa.ts.net:4318";
        description = "Base URL of the collector's OTLP/HTTP receiver; /v1/metrics is appended. Tailnet-only by default.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.between 15 600;
        default = 60;
        description = "Seconds between pushes (launchd StartInterval).";
      };
    };
    networkIsolation = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Keep the runner user's jobs off private, link-local, loopback and tailnet addresses with a pf anchor
          (olympus-sdk #394 F4). The loop loads it and enables pf before every registration and registers no runner
          if it is not in force. Turning this off flushes the anchor on the next iteration.
        '';
      };
      anchor = lib.mkOption {
        type = lib.types.str;
        default = "com.apple/400.olympus-ci-runner";
        description = "The pf anchor, a child of Apple's com.apple anchor point that /etc/pf.conf already evaluates.";
      };
      dnsResolvers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra private DNS resolvers the runner user may query on port 53. The IPv4 nameservers in /etc/resolv.conf
          (the DHCP-provided gateway) are added by the loop every time it loads the anchor.
        '';
      };
      allowedDestinations = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              address = lib.mkOption {
                type = lib.types.str;
                description = "An address or CIDR that would otherwise be blocked.";
              };
              port = lib.mkOption {
                type = lib.types.port;
                description = "The TCP port allowed on it.";
              };
            };
          }
        );
        default = [ ];
        description = "Narrow TCP exceptions to the private ranges, e.g. a CI service that only has a private address.";
      };
      blockedIPv4 = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "0.0.0.0/8"
          "10.0.0.0/8"
          "100.64.0.0/10"
          "169.254.0.0/16"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "224.0.0.0/4"
          "255.255.255.255"
        ];
        description = "IPv4 destinations the runner user may not reach (RFC 1918, CGNAT/tailnet, link-local, multicast). Loopback: loopbackMinPort.";
      };
      blockIPv6 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Block all IPv6 for the runner user. Off (default): the site's own global prefixes (<ci_lan6>, found at runtime) and blockedIPv6.";
      };
      blockedIPv6 = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "fc00::/7"
          "fe80::/10"
          "ff00::/8"
        ];
        description = "IPv6 destinations blocked besides <ci_lan6> when blockIPv6 is off (fc00::/7 covers the tailnet's fd7a:115c:a1e0::/48).";
      };
      rules = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        description = "The generated pf rules (read-only; for tests and review).";
      };
      loopbackMinPort = lib.mkOption {
        type = lib.types.port;
        default = 49152;
        description = "Lowest loopback port the runner user may connect to (the start of the macOS ephemeral range).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    d.server.ciRunner.networkIsolation.rules = pfText;

    # Skipped when the user is root or the primary user, so the assertion below is what reports it.
    users = lib.mkIf (dedicated) {
      knownGroups = [ cfg.user ];
      knownUsers = [ cfg.user ];
      groups.${cfg.user} = {
        gid = id;
        description = "CI runner group";
      };
      users.${cfg.user} = {
        uid = id;
        gid = id;
        isHidden = true;
        createHome = false;
        home = "${cfg.workDir}/home";
        shell = null;
        description = "CI runner";
      };
    };

    # nix-darwin's user activation runs `realpath` on an existing user's home, which fails when the directory is
    # missing (the loop recreates it after every job, but it may not exist yet). Create it before the user step.
    # The log (job names, runner output) is root-only (#394 F13). launchd creates StandardOutPath 0644 when it is
    # missing and keeps the mode of an existing file, so it is created 0600 before the daemon loads; the loop
    # re-asserts the mode every iteration. No newsyslog entry: one line per job, and launchd would keep writing to
    # the rotated file.
    system.activationScripts.preActivation.text = lib.mkAfter ''
      /usr/bin/install -d -m 0755 -o root -g wheel ${lib.escapeShellArg cfg.workDir}
      /usr/bin/install -d -m 0700 -o root -g wheel ${lib.escapeShellArg (dirOf cfg.stateFile)}
      /bin/mkdir -p ${lib.escapeShellArg "${cfg.workDir}/home"}
      /usr/bin/touch ${logFile}
      /usr/sbin/chown root:wheel ${logFile}
      /bin/chmod 0600 ${logFile}
      /usr/bin/touch ${hbLog}
      /usr/sbin/chown root:wheel ${hbLog}
      /bin/chmod 0600 ${hbLog}
    '';

    # After the users step (#394 F1a, F13):
    # - cron and at are denied to the runner user. /usr/lib/cron is Apple's symlink to /private/var/at (not SIP
    #   protected). A deny entry rather than a cron.allow allow-list: cron.allow would also lock out every account
    #   not listed (ansible, the owner, future service users), which this role does not own. at is off on macOS
    #   (com.apple.atrun is not loaded); the entry covers someone turning it on. The loop checks both entries and
    #   registers no runner without them.
    # - the runner user is taken out of any Public-folder share group it is a direct member of. On these Macs the
    #   membership comes from the group nesting `everyone` (every account is a member), which a user record cannot
    #   leave; the network side is closed by the pf anchor (SMB on loopback and the LAN).
    system.activationScripts.postActivation.text = lib.mkAfter ''
      for f in /usr/lib/cron/cron.deny /usr/lib/cron/at.deny; do
        [ -f "$f" ] || /usr/bin/install -m 0644 -o root -g wheel /dev/null "$f"
        /usr/bin/grep -qxF ${lib.escapeShellArg cfg.user} "$f" || printf '%s\n' ${lib.escapeShellArg cfg.user} >>"$f"
      done
      for g in $(/usr/bin/dscl . -list /Groups | /usr/bin/grep '^com\.apple\.sharepoint\.group\.'); do
        if /usr/bin/dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qxF ${lib.escapeShellArg cfg.user}; then
          /usr/sbin/dseditgroup -o edit -d ${lib.escapeShellArg cfg.user} -t user "$g" || true
        fi
      done
    '';

    launchd.daemons.ci-runner = {
      serviceConfig = {
        Label = "io.olympus.ci-runner";
        # At boot launchd starts daemons before the /nix volume is mounted; a store path as the program is then a
        # "Missing executable" and launchd disables the job for good (mmini-01, 2026-10-31). Wait for the store first,
        # as nix-darwin's own daemons do.
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${loop}"
        ];
        EnvironmentVariables = {
          PATH =
            # No GNU coreutils: the loop is written for the macOS (BSD) stat, cp -c and install; GNU `stat -f`
            # means filesystem status and made every credential check fail.
            lib.makeBinPath [
              pkgs.curl
              pkgs.jq
              pkgs.openssl
            ]
            + ":/usr/bin:/bin:/usr/sbin:/sbin";
          CI_ORG = cfg.org;
          CI_GROUP = cfg.group;
          CI_LABELS = lib.concatStringsSep "," cfg.labels;
          CI_APP_ID_FILE = cfg.appIdFile;
          CI_INSTALLATION_ID_FILE = cfg.installationIdFile;
          CI_PRIVATE_KEY_FILE = cfg.privateKeyFile;
          CI_USER = cfg.user;
          CI_WORK_DIR = cfg.workDir;
          CI_RUNNER_DIR = "${runner}";
          CI_NICE = toString cfg.nice;
          CI_PF_ANCHOR = net.anchor;
          CI_PF_RULES = if net.enable then "${pfRules}" else "";
          CI_LOG_FILE = logFile;
          CI_STATE_FILE = cfg.stateFile;
        };
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };

    # One push per StartInterval; the job runs for a second and exits. Only failures are logged (root-only log,
    # rotated by newsyslog: launchd reopens it on every run).
    launchd.daemons.ci-runner-heartbeat = lib.mkIf hb.enable {
      serviceConfig = {
        Label = "io.olympus.ci-runner-heartbeat";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${heartbeat}"
        ];
        EnvironmentVariables = {
          PATH =
            lib.makeBinPath [
              pkgs.curl
              pkgs.jq
            ]
            + ":/usr/bin:/bin:/usr/sbin:/sbin";
          CI_HB_ENDPOINT = hb.endpoint;
          CI_HB_LABEL = "io.olympus.ci-runner";
          CI_USER = cfg.user;
          CI_STATE_FILE = cfg.stateFile;
        };
        RunAtLoad = true;
        StartInterval = hb.interval;
        StandardOutPath = hbLog;
        StandardErrorPath = hbLog;
      };
    };
    environment.etc."newsyslog.d/ci-runner-heartbeat.conf" = lib.mkIf hb.enable {
      text = ''
        # logfilename                  [owner:group]  mode count size(KB) when flags
        ${hbLog}  root:wheel     600  3     1024     *    N
      '';
    };

    assertions = [
      {
        assertion = server.enable;
        message = "d.server.ciRunner needs d.server.enable: the runner is part of the server role.";
      }
      {
        assertion = dedicated;
        message = "d.server.ciRunner.user must be a dedicated unprivileged user, not root or the primary user.";
      }
      {
        assertion = lib.all (lib.hasPrefix "/") [
          cfg.workDir
          cfg.appIdFile
          cfg.installationIdFile
          cfg.privateKeyFile
          cfg.stateFile
        ];
        message = "d.server.ciRunner: workDir, stateFile and the credential file paths must be absolute.";
      }
      {
        assertion = !(lib.hasPrefix "${cfg.workDir}/" cfg.stateFile);
        message = "d.server.ciRunner: stateFile must live outside workDir, which is wiped.";
      }
      {
        assertion =
          !(lib.any (lib.hasPrefix "${cfg.workDir}/") [
            cfg.appIdFile
            cfg.installationIdFile
            cfg.privateKeyFile
          ]);
        message = "d.server.ciRunner: the credential files must live outside workDir, which is wiped and owned by the runner user.";
      }
    ];
  };
}
