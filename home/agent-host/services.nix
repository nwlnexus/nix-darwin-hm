# claude-<acct> / codex-<acct> launchers, the always-on Remote Control services
# built on them (systemd user units on Linux, boot-time launchd daemons on macOS
# that run as the user, declared here and installed by system/darwin/agent-host.nix),
# and the `agents` helper. Binaries are the native installs in ~/.local/bin (they
# self-update); Nix only wraps them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost;
  home = config.home.homeDirectory;
  inherit (pkgs.stdenv) isDarwin;

  tools = {
    claude = {
      dirVar = "CLAUDE_CONFIG_DIR";
      dir = acct: "${home}/.claude-${acct}";
      creds = ".credentials.json";
      serverArgs = [ "remote-control" ];
    };
    codex = {
      dirVar = "CODEX_HOME";
      dir = acct: "${home}/.codex-${acct}";
      creds = "auth.json";
      # Codex 0.159's foreground `remote-control` fails its socket-parent
      # check ("socket parent must be owned by the user or root ..."), while
      # its managed daemon works, so the unit starts/stops the daemon.
      daemon = {
        start = [
          "remote-control"
          "start"
        ];
        stop = [
          "remote-control"
          "stop"
        ];
      };
    };
  };

  # Services get no login shell, so give agent sessions the user's tool PATH.
  # nix-darwin installs home.packages into the per-user profile
  # (home.profileDirectory) and system packages into /run/current-system.
  agentPath = lib.concatStringsSep ":" (
    if isDarwin then
      [
        "${home}/.local/bin"
        "${home}/.local/share/mise/shims"
        "${config.home.profileDirectory}/bin"
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
        "${home}/.cargo/bin"
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
        # Last: brew never shadows Nix/mise.
        "/opt/homebrew/bin"
        "/opt/homebrew/sbin"
      ]
    else
      [
        "${home}/.local/bin"
        "${home}/.local/share/mise/shims"
        "${home}/.nix-profile/bin"
        "/nix/var/nix/profiles/default/bin"
        "${home}/.cargo/bin"
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
      ]
      # Last, as in the shell (home/linuxbrew.nix): brew never shadows Nix/mise.
      ++ lib.optionals (config.d.linuxbrew.enable or false) [
        "${config.d.linuxbrew.prefix}/bin"
        "${config.d.linuxbrew.prefix}/sbin"
      ]
  );

  # Pin the account, load its tree's op-provisioned .env (tokens), exec the
  # native binary. Used interactively and as the services' ExecStart.
  mkLauncher =
    tool: acct: account:
    let
      t = tools.${tool};
      envFile = "${account.root}/.env";
      profile = if isDarwin then config.home.profileDirectory else "${home}/.nix-profile";
      sessionVars = "${profile}/etc/profile.d/hm-session-vars.sh";
    in
    pkgs.writeShellScriptBin "${tool}-${acct}" ''
      if [ -f ${lib.escapeShellArg sessionVars} ]; then
        . ${lib.escapeShellArg sessionVars}
      fi
      export ${t.dirVar}=${lib.escapeShellArg (t.dir acct)}
      # Codex refuses a CODEX_HOME that doesn't exist yet.
      mkdir -p "''${${t.dirVar}}"
      if [ -f ${lib.escapeShellArg envFile} ]; then
        set -a
        . ${lib.escapeShellArg envFile}
        set +a
      fi
      if [ -n "''${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
        export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
      fi
      exec ${lib.escapeShellArg "${home}/.local/bin/${tool}"} "$@"
    '';

  pairs = lib.concatMap (
    tool:
    lib.mapAttrsToList (acct: account: {
      inherit tool acct account;
      launcher = mkLauncher tool acct account;
    }) cfg.accounts
  ) (lib.attrNames tools);

  # Only the pairs whose Remote Control service is on (accounts.<a>.remoteControl.<tool>).
  rcPairs = lib.filter (p: p.account.remoteControl.${p.tool}) pairs;

  unitName = p: "${p.tool}-rc-${p.acct}";
  units = map unitName rcPairs;

  creds = p: "${tools.${p.tool}.dir p.acct}/${tools.${p.tool}.creds}";
  logFile = name: "${cfg.logDir}/${name}.log";

  # macOS login check. Claude Code on macOS keeps its OAuth token in the
  # Keychain, so the credentials file may never appear; `/login` also records
  # `oauthAccount` in the account's .claude.json, so either counts. Codex asks
  # its own CLI (file or keyring store alike).
  darwinLoggedIn =
    p:
    let
      dir = tools.${p.tool}.dir p.acct;
    in
    if p.tool == "claude" then
      "[ -f ${lib.escapeShellArg (creds p)} ] || grep -q '\"oauthAccount\"' ${lib.escapeShellArg "${dir}/.claude.json"} 2>/dev/null"
    else
      "${p.launcher}/bin/${p.tool}-${p.acct} login status >/dev/null 2>&1";

  # macOS: launchd has no ExecCondition, so the agent's program waits (one
  # check a minute, logged once) until the account is logged in, then starts
  # the server; KeepAlive restarts it whenever it exits.
  # POSIX sh (macOS /bin/sh), inline in the plist so `launchctl print` shows it.
  darwinRcScript =
    p:
    let
      t = tools.${p.tool};
      bin = "${p.launcher}/bin/${p.tool}-${p.acct}";
    in
    ''
      logged_in() { ${darwinLoggedIn p}; }
      if ! logged_in; then
        echo "$(date '+%F %T') ${p.acct} is not logged in to ${p.tool}; waiting (log in with ${p.tool}-${p.acct})"
        until logged_in; do sleep 60; done
        echo "$(date '+%F %T') ${p.acct} logged in; starting"
      fi
    ''
    + (
      if t ? daemon then
        # The equivalent of the Linux oneshot + RemainAfterExit: (re)start the
        # managed daemon, then stay up so launchd can stop it (and a
        # `kickstart -k` restarts it).
        ''
          ${bin} ${lib.escapeShellArgs t.daemon.stop} >/dev/null 2>&1 || true
          ${bin} ${lib.escapeShellArgs t.daemon.start} || exit 1
          trap '${bin} ${lib.escapeShellArgs t.daemon.stop}; exit 0' TERM INT HUP
          while :; do
            sleep 86400 &
            wait $!
          done
        ''
      else
        ''
          exec ${bin} ${lib.escapeShellArgs t.serverArgs}
        ''
    );

  # macOS Remote Control are system LaunchDaemons (they start at boot with nobody logged in), so mise shims
  # (which can install tools on demand) stay out of their PATH.
  daemonPath = lib.concatStringsSep ":" (
    lib.filter (d: d != "${home}/.local/share/mise/shims") (lib.splitString ":" agentPath)
  );
  daemonLabel = u: "io.olympus.agent-host.${u}";
  # Label of the pre-daemon home-manager LaunchAgents these replace.
  oldAgentLabel = u: "org.nix-community.home.${u}";

  agentsText =
    if isDarwin then
      ''
        units=(${lib.escapeShellArgs units})
        labels=(${lib.escapeShellArgs (map daemonLabel units)})
        logdir=${lib.escapeShellArg cfg.logDir}
        domain="system"
        label_of() {
          local i
          for i in "''${!units[@]}"; do
            if [ "''${units[$i]}" = "$1" ]; then
              echo "''${labels[$i]}"
              return 0
            fi
          done
          echo "agents: unknown unit '$1' (known: ''${units[*]})" >&2
          return 1
        }
        case "''${1:-status}" in
          status)
            printf '%-24s %-12s %-8s %s\n' UNIT STATE PID LAST-EXIT
            for u in "''${units[@]}"; do
              l="$(label_of "$u")"
              if out="$(launchctl print "$domain/$l" 2>/dev/null || sudo -n launchctl print "$domain/$l" 2>/dev/null)"; then
                state="$(awk -F' = ' '$1 ~ /^[[:space:]]*state$/ { print $2; exit }' <<<"$out")"
                pid="$(awk -F' = ' '$1 ~ /^[[:space:]]*pid$/ { print $2; exit }' <<<"$out")"
                last="$(awk -F' = ' '$1 ~ /^[[:space:]]*last exit code$/ { print $2; exit }' <<<"$out")"
                printf '%-24s %-12s %-8s %s\n' "$u" "''${state:-?}" "''${pid:--}" "''${last:--}"
              else
                printf '%-24s %-12s %-8s %s\n' "$u" "not-loaded" - -
              fi
            done
            ;;
          restart)
            shift
            if [ $# -eq 0 ]; then
              set -- "''${units[@]}"
            fi
            for u in "$@"; do
              l="$(label_of "$u")"
              sudo launchctl kickstart -k "$domain/$l"
            done
            ;;
          logs)
            if [ $# -lt 2 ]; then
              echo "usage: agents logs <unit>" >&2
              exit 2
            fi
            label_of "$2" >/dev/null
            tail -n 100 -F "$logdir/$2.log"
            ;;
          *)
            echo "usage: agents [status | restart [unit...] | logs <unit>]" >&2
            exit 2
            ;;
        esac
      ''
    else
      ''
        units=(${lib.escapeShellArgs units})
        case "''${1:-status}" in
          status)
            systemctl --user --no-pager list-units --all "''${units[@]/%/.service}"
            ;;
          restart)
            shift
            if [ $# -gt 0 ]; then
              systemctl --user restart "$@"
            else
              systemctl --user restart "''${units[@]}"
            fi
            ;;
          logs)
            if [ $# -lt 2 ]; then
              echo "usage: agents logs <unit>" >&2
              exit 2
            fi
            journalctl --user -u "$2" -f
            ;;
          *)
            echo "usage: agents [status | restart [unit...] | logs <unit>]" >&2
            exit 2
            ;;
        esac
      '';

  agents = pkgs.writeShellApplication {
    name = "agents";
    text = agentsText;
  };
in
lib.mkIf cfg.enable {
  home.packages = map (p: p.launcher) pairs ++ [ agents ];

  # macOS: no launchd.agents for Remote Control. The daemon specs are exposed for system/darwin/agent-host.nix,
  # which installs them as LaunchDaemons running as this user.
  d.agentHost.darwinDaemons = lib.optionalAttrs isDarwin (
    lib.listToAttrs (
      map (
        p:
        lib.nameValuePair (unitName p) {
          Label = daemonLabel (unitName p);
          ProgramArguments = [
            "/bin/sh"
            "-c"
            (darwinRcScript p)
          ];
          WorkingDirectory = p.account.root;
          UserName = config.home.username;
          GroupName = "staff";
          EnvironmentVariables = {
            HOME = home;
            USER = config.home.username;
            LOGNAME = config.home.username;
            PATH = daemonPath;
            MISE_AUTO_INSTALL = "0";
          };
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 10;
          StandardInPath = "/dev/null";
          StandardOutPath = logFile (unitName p);
          StandardErrorPath = logFile (unitName p);
        }
      ) rcPairs
    )
  );

  # Migration: the old per-user agents are removed by home-manager's setupLaunchAgents (it boots out and
  # deletes agents that vanish from the generation), but only when the previous generation is known and the
  # plist is unchanged. Do it here too, so two servers for one account can never run side by side.
  home.activation.agentHostRetireOldAgents = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "setupLaunchAgents" ] (
      lib.concatMapStrings (u: ''
        /bin/launchctl bootout "gui/$UID/${oldAgentLabel u}" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/${oldAgentLabel u}.plist" || true
      '') units
    )
  );

  systemd.user.services = lib.mkIf (!isDarwin) (
    lib.listToAttrs (
      map (
        p:
        lib.nameValuePair (unitName p) {
          Unit.Description = "${p.tool} Remote Control (${p.acct})";
          Service =
            let
              t = tools.${p.tool};
              bin = "${p.launcher}/bin/${p.tool}-${p.acct}";
            in
            {
              WorkingDirectory = p.account.root;
              Environment = [ "PATH=${agentPath}" ];
              # Skip (not fail) until this account is logged in.
              ExecCondition = "${pkgs.coreutils}/bin/test -f ${t.dir p.acct}/${t.creds}";
              RestartSec = 10;
              StandardInput = "null";
            }
            // (
              if t ? daemon then
                {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = "${bin} ${lib.escapeShellArgs t.daemon.start}";
                  ExecStop = "${bin} ${lib.escapeShellArgs t.daemon.stop}";
                  Restart = "on-failure";
                }
              else
                {
                  Type = "simple";
                  ExecStart = "${bin} ${lib.escapeShellArgs t.serverArgs}";
                  Restart = "always";
                }
            );
          Install.WantedBy = [ "default.target" ];
        }
      ) rcPairs
    )
  );
}
