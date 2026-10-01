# Linux agent hosts: one Claude Code / Codex config dir per account, with the
# account picked by the project tree you're in (direnv) or explicitly via
# claude-<acct> / codex-<acct>. Remote Control services: ./services.nix.
{
  config,
  lib,
  ...
}:
let
  cfg = config.d.agentHost;
  home = config.home.homeDirectory;
  claudeDir = acct: "${home}/.claude-${acct}";
  codexDir = acct: "${home}/.codex-${acct}";
  accts = lib.attrNames cfg.accounts;
in
{
  imports = [ ./services.nix ];

  options.d.agentHost = {
    enable = lib.mkEnableOption "per-account Claude Code / Codex and Remote Control services";

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      default = "personal";
      description = "Account used outside every account's project tree.";
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.root = lib.mkOption {
            type = lib.types.str;
            description = "Project tree this account works in (Remote Control working directory).";
          };
        }
      );
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.accounts ? ${cfg.defaultAccount};
        message = "d.agentHost.defaultAccount must name an entry in d.agentHost.accounts";
      }
    ];

    home.sessionVariables = {
      CLAUDE_CONFIG_DIR = claudeDir cfg.defaultAccount;
      CODEX_HOME = codexDir cfg.defaultAccount;
    };

    home.file = lib.mkMerge (
      map (acct: {
        ".claude-${acct}/commands/brain.md".source = ../cli/claude/commands/brain.md;
      }) accts
    );

    # Pick the account from $PWD at every prompt. Runs after direnv's hook
    # (registered earlier in .zshrc), so a repo's own .envrc can't drop it --
    # direnv only loads the nearest .envrc, which is why this isn't one.
    programs.zsh.initContent = lib.mkOrder 2000 ''
      _agent_host_account() {
        case "$PWD/" in
      ${
        lib.concatMapStrings (acct: ''
          ${cfg.accounts.${acct}.root}/*) export CLAUDE_CONFIG_DIR=${claudeDir acct} CODEX_HOME=${codexDir acct} ;;
        '') accts
      }    *) export CLAUDE_CONFIG_DIR=${claudeDir cfg.defaultAccount} CODEX_HOME=${codexDir cfg.defaultAccount} ;;
        esac
      }
      precmd_functions+=(_agent_host_account)
    '';

    # Per-account gitnexus Claude integration (home/cli/claude does ~/.claude).
    home.activation.agentHostGitnexus = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (acct: ''
        GITNEXUS_BIN="${home}/.local/share/mise/shims/gitnexus"
        if [ -x "$GITNEXUS_BIN" ]; then
          CLAUDE_CONFIG_DIR=${lib.escapeShellArg (claudeDir acct)} "$GITNEXUS_BIN" setup -c claude || true
        fi
      '') accts
    );
  };
}
