# Linux agent hosts: one Claude Code / Codex config dir per account, with the
# account picked by the project tree you're in (direnv) or explicitly via
# claude-<acct> / codex-<acct>. Remote Control services: ./services.nix.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agentSkills = inputs.agent-skills;
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

    # Per account: /brain command + every skills/<name> from the agent-skills
    # input (same set home/cli/claude puts under ~/.claude).
    home.file = lib.mkMerge (
      map (
        acct:
        {
          ".claude-${acct}/commands/brain.md".source = ../cli/claude/commands/brain.md;
        }
        // lib.listToAttrs (
          map
            (
              name:
              lib.nameValuePair ".claude-${acct}/skills/${name}" { source = "${agentSkills}/skills/${name}"; }
            )
            (
              lib.attrNames (
                lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${agentSkills}/skills")
              )
            )
        )
      ) accts
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

    # Codex refuses to start when CODEX_HOME doesn't exist; create every
    # account's config dirs up front (private: they hold credentials).
    home.activation.agentHostDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (acct: ''
        run install -d -m 0700 ${claudeDir acct}
        run install -d -m 0700 ${codexDir acct}
      '') accts
    );

    # Per-account gitnexus Claude integration (home/cli/claude does ~/.claude).
    #
    # `gitnexus setup -c claude` ignores CLAUDE_CONFIG_DIR: it always writes the
    # MCP server to ~/.claude.json and the skills to ~/.claude/skills. Running
    # it per account therefore configured nothing for the account dirs, so
    # sessions using ~/.claude-<acct> had no gitnexus MCP tools. Write the
    # user-scope mcpServers.gitnexus entry and mirror the gitnexus-* skills
    # into every account dir. The entry runs the installed mise shim, not
    # `npx -y gitnexus@x mcp`: npx re-resolves against the registry on every
    # start (slow, and a TLS/network hiccup blows the 30s MCP connect timeout),
    # while the shim starts in <1s offline and resolves its own node.
    # Idempotent, fail-soft.
    home.activation.agentHostGitnexus = lib.hm.dag.entryAfter [ "gitnexusSetup" ] (
      lib.concatMapStrings (acct: ''
        SHIM=${lib.escapeShellArg "${home}/.local/share/mise/shims/gitnexus"}
        ACCT_DIR=${lib.escapeShellArg (claudeDir acct)}
        if [ -x "$SHIM" ]; then
          DST_JSON="$ACCT_DIR/.claude.json"
          [ -f "$DST_JSON" ] || { echo '{}' > "$DST_JSON"; chmod 600 "$DST_JSON"; }
          TMP="$(mktemp)"
          if ${pkgs.jq}/bin/jq --arg c "$SHIM" '.mcpServers.gitnexus = {command: $c, args: ["mcp"]}' "$DST_JSON" > "$TMP" 2>/dev/null; then
            if cmp -s "$TMP" "$DST_JSON"; then rm -f "$TMP"; else chmod 600 "$TMP"; mv "$TMP" "$DST_JSON"; fi
          else
            rm -f "$TMP"
          fi
        fi
        for SKILL in ${home}/.claude/skills/gitnexus-*; do
          [ -d "$SKILL" ] || continue
          # Our agent-skills are nix-managed symlinks in both places; cp onto
          # a store symlink would fail. Only mirror real (gitnexus-written) dirs.
          [ -L "$SKILL" ] && continue
          run install -d -m 0755 "$ACCT_DIR/skills"
          run cp -rT "$SKILL" "$ACCT_DIR/skills/$(basename "$SKILL")"
        done
      '') accts
    );
  };
}
