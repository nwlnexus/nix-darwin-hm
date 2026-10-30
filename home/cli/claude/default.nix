# home/cli/claude/default.nix
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  agentSkills = inputs.agent-skills;
  # Our reusable skills (github:nwlnexus/agent-skills, flake input): every
  # skills/<name> becomes <claude dir>/skills/<name>. Ours, not gitnexus's, so
  # they are nix-managed symlinks and the gitnexus-* mirroring in
  # home/agent-host skips them (it builds the same set per account dir).
  skillDirs = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${agentSkills}/skills")
  );
  skillFiles =
    claudeDir:
    lib.listToAttrs (
      map (
        name: lib.nameValuePair "${claudeDir}/skills/${name}" { source = "${agentSkills}/skills/${name}"; }
      ) skillDirs
    );
in
{
  # agents/ + the session-contract block in CLAUDE.md + the progress-stale Stop hook, per Claude dir; the
  # agent-session tmux launcher.
  imports = [
    ./harness.nix
    ./agent-session.nix
  ];

  home.file = {
    # /brain slash command (consult + ingest the second-brain wiki). Not on a work-only host
    # (home/work-only.nix): the wiki is personal.
    ".claude/commands/brain.md" = {
      enable = !config.d.workOnly.enable;
      source = ./commands/brain.md;
    };
  }
  // skillFiles ".claude";

  # Obsidian vault on the Macs; the agent host overrides it (home/agent-host/second-brain.nix). A work-only host
  # gets no SECOND_BRAIN_PATH at all, so nothing falls back to the personal vault.
  home.sessionVariables = lib.mkIf (!config.d.workOnly.enable) {
    SECOND_BRAIN_PATH = lib.mkDefault "${config.home.homeDirectory}/Documents/Obsidian Vault/brain";
  };

  # mnemosyne is retired. Its `install-hooks` wrote entries straight into
  # ~/.claude/settings.json and ~/.cursor/hooks.json (outside Nix), so nothing
  # removes them on its own — strip them, plus its mise install and state dir,
  # on each activation until every host has switched, then delete this block.
  # Idempotent (each step is a no-op once done) and fail-soft. Root-owned
  # leftovers are handled in system/darwin/default.nix.
  home.activation.mnemosyneCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    strip() { # file jq-filter
      [ -f "$1" ] || return 0
      TMP="$(mktemp)"
      if ${pkgs.jq}/bin/jq "$2" "$1" > "$TMP" 2>/dev/null && ! cmp -s "$TMP" "$1"; then
        mv "$TMP" "$1"
      else
        rm -f "$TMP"
      fi
    }
    strip "${config.home.homeDirectory}/.claude/settings.json" '
      if .hooks then .hooks |= (with_entries(
        .value |= map(select((.hooks // []) | all(.command // "" | test("mnemosyne|moneta-recall-hook|mem0") | not)))
      ) | with_entries(select(.value | length > 0))) else . end'
    strip "${config.home.homeDirectory}/.cursor/hooks.json" '
      if .hooks then .hooks |= (with_entries(
        .value |= map(select((.command // "") | test("mnemosyne") | not))
      ) | with_entries(select(.value | length > 0))) else . end'

    # Retired memory MCP servers (moneta, openmemory/mem0) left in Claude's config by hand-run
    # `claude mcp add`: drop them from the user scope and from every per-project scope.
    retiredMcp='def drop: if type == "object" then with_entries(select((.key | test("^(moneta|openmemory|mem0)$"; "i")) | not)) else . end;
      (if .mcpServers then .mcpServers |= drop else . end)
      | (if .projects then .projects |= map_values(if .mcpServers then .mcpServers |= drop else . end) else . end)'
    for f in "${config.home.homeDirectory}/.claude.json" "${config.home.homeDirectory}"/.claude-*/.claude.json; do
      strip "$f" "$retiredMcp"
    done

    rm -rf "${config.home.homeDirectory}/.claude/mnemosyne"
    MISE_DATA="${config.home.homeDirectory}/.local/share/mise"
    if [ -d "$MISE_DATA/installs/npm-nwlnexus-mnemosyne" ]; then
      PATH="${pkgs.mise}/bin:$PATH" ${pkgs.mise}/bin/mise uninstall --all npm:@nwlnexus/mnemosyne 2>&1 || true
      rm -rf "$MISE_DATA/installs/npm-nwlnexus-mnemosyne"
      PATH="${pkgs.mise}/bin:$PATH" ${pkgs.mise}/bin/mise reshim 2>&1 || true
    fi
  '';

  # gitnexus ships its own installer; it is idempotent and non-interactive.
  # NOTE it only ever targets ~/.claude (ignores CLAUDE_CONFIG_DIR); agent-host
  # mirrors its output into the per-account dirs (home/agent-host).
  # gitnexus is a mise global (npm:gitnexus, see home/default.nix), not a
  # nixpkgs package, so it has no nix store path and isn't on the activation
  # script's PATH — resolve it by absolute path instead.
  #
  # The SHIM, not `installs/npm-gitnexus/latest/bin/gitnexus`: that install path
  # is a `#!/usr/bin/env node` script, and `node` is itself a mise global that is
  # NOT on the activation script's PATH either — so the old path failed with
  # `env: node: No such file or directory` and, being `|| true`, failed silently
  # on every rebuild. The shim is the mise binary itself and resolves its own
  # node.
  # Fail-soft: a fresh host may not have the mise global installed yet.
  home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GITNEXUS_BIN="${config.home.homeDirectory}/.local/share/mise/shims/gitnexus"
    if [ -x "$GITNEXUS_BIN" ]; then
      "$GITNEXUS_BIN" setup -c claude || true
    fi
  '';
}
