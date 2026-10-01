# claude-<acct> / codex-<acct> launchers, the always-on Remote Control user
# services built on them, and the `agents` helper. Binaries are the native
# installs in ~/.local/bin (they self-update); Nix only wraps them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost;
  home = config.home.homeDirectory;

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
      # Foreground form; `remote-control start` would daemonize away from systemd.
      serverArgs = [ "remote-control" ];
    };
  };

  # Services get no login shell, so give agent sessions the user's tool PATH.
  agentPath = lib.concatStringsSep ":" [
    "${home}/.local/bin"
    "${home}/.local/share/mise/shims"
    "${home}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "${home}/.cargo/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  # Pin the account, load its tree's op-provisioned .env (tokens), exec the
  # native binary. Used interactively and as the services' ExecStart.
  mkLauncher =
    tool: acct: account:
    let
      t = tools.${tool};
      envFile = "${account.root}/.env";
      sessionVars = "${home}/.nix-profile/etc/profile.d/hm-session-vars.sh";
    in
    pkgs.writeShellScriptBin "${tool}-${acct}" ''
      if [ -f ${lib.escapeShellArg sessionVars} ]; then
        . ${lib.escapeShellArg sessionVars}
      fi
      export ${t.dirVar}=${lib.escapeShellArg (t.dir acct)}
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

  unitName = p: "${p.tool}-rc-${p.acct}";
  units = map unitName pairs;

  agents = pkgs.writeShellApplication {
    name = "agents";
    text = ''
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
  };
in
lib.mkIf cfg.enable {
  home.packages = map (p: p.launcher) pairs ++ [ agents ];

  systemd.user.services = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair (unitName p) {
        Unit.Description = "${p.tool} Remote Control (${p.acct})";
        Service = {
          Type = "simple";
          WorkingDirectory = p.account.root;
          Environment = [ "PATH=${agentPath}" ];
          # Skip (not fail) until this account is logged in.
          ExecCondition = "${pkgs.coreutils}/bin/test -f ${tools.${p.tool}.dir p.acct}/${tools.${p.tool}.creds}";
          ExecStart = "${p.launcher}/bin/${p.tool}-${p.acct} ${
            lib.escapeShellArgs tools.${p.tool}.serverArgs
          }";
          Restart = "always";
          RestartSec = 10;
          StandardInput = "null";
        };
        Install.WantedBy = [ "default.target" ];
      }
    ) pairs
  );
}
