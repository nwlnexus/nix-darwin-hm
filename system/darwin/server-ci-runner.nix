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

  # The runner user's uid and gid: the range nix-darwin's own runner module uses for its service account.
  id = 533;
  dedicated = cfg.user != "root" && cfg.user != primary;
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
      description = "The organization runner group, by name; its id is looked up on every registration.";
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
  };

  config = lib.mkIf cfg.enable {
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
    system.activationScripts.preActivation.text = lib.mkAfter ''
      /usr/bin/install -d -m 0755 -o root -g wheel ${lib.escapeShellArg cfg.workDir}
      /bin/mkdir -p ${lib.escapeShellArg "${cfg.workDir}/home"}
    '';

    launchd.daemons.ci-runner = {
      serviceConfig = {
        Label = "io.olympus.ci-runner";
        ProgramArguments = [ "${loop}" ];
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
        };
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = "/var/log/ci-runner.log";
        StandardErrorPath = "/var/log/ci-runner.log";
      };
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
        ];
        message = "d.server.ciRunner: workDir and the credential file paths must be absolute.";
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
