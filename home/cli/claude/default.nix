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

  # GitNexus for ~/.claude, owned here rather than by `gitnexus setup -c claude`. That installer also registered
  # its own Claude Code hooks (PreToolUse on Grep|Glob|Bash, PostToolUse on Bash: a Node script with a 10 s
  # timeout on every such tool call) and wrote an `npx` MCP entry when the binary was not on PATH. The owner
  # chose to drop the hooks (2026-11-01), so this step does only what is wanted:
  #   1. copies the gitnexus skills from the installed package (`mise where npm:gitnexus`) into ~/.claude/skills,
  #      as `gitnexus setup` laid them out (<name>/SKILL.md; folder skills copied whole). Nix-managed skill links
  #      (agent-skills, e.g. gitnexus-no-churn) are never touched. home/agent-host mirrors these into each
  #      ~/.claude-<acct>;
  #   2. removes the hooks an earlier `gitnexus setup` registered (entries whose command mentions
  #      `gitnexus-hook`) and their scripts in ~/.claude/hooks/gitnexus;
  #   3. writes the MCP entry, even before the shim exists (a fresh host installs the mise global after the first
  #      switch), always the shim, never npx. Same entry as home/agent-host writes per account.
  # gitnexus is a mise global (npm:gitnexus, home/default.nix); the shim resolves its own node. Fail-soft throughout.
  home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GITNEXUS_BIN="${config.home.homeDirectory}/.local/share/mise/shims/gitnexus"
    CLAUDE_DIR="${config.home.homeDirectory}/.claude"
    JQ=${pkgs.jq}/bin/jq

    # 1. skills
    PKG_SKILLS="$(${config.programs.mise.package}/bin/mise where npm:gitnexus 2>/dev/null)/lib/node_modules/gitnexus/skills"
    if [ -d "$CLAUDE_DIR" ] && [ -d "$PKG_SKILLS" ]; then
      run install -d "$CLAUDE_DIR/skills"
      for src in "$PKG_SKILLS"/gitnexus-*; do
        [ -e "$src" ] || continue
        name="$(basename "$src" .md)"
        dest="$CLAUDE_DIR/skills/$name"
        [ -L "$dest" ] && continue
        if [ -d "$src" ]; then
          [ -f "$src/SKILL.md" ] || continue
          run rm -rf "$dest"
          run cp -R "$src" "$dest"
        else
          run install -d "$dest"
          run install -m 0644 "$src" "$dest/SKILL.md"
        fi
      done
    fi

    # 2. drop the hooks an earlier `gitnexus setup` registered
    SETTINGS="$CLAUDE_DIR/settings.json"
    if [ -f "$SETTINGS" ]; then
      TMP="$(mktemp)"
      if $JQ '
        if (.hooks | type) == "object" then
          .hooks |= (with_entries(.value |= map(select(
                       ((.hooks // []) | map(.command // "") | any(test("gitnexus-hook"))) | not)))
                     | with_entries(select((.value | length) > 0)))
        else . end' "$SETTINGS" > "$TMP" 2>/dev/null; then
        if cmp -s "$TMP" "$SETTINGS"; then rm -f "$TMP"; else run mv "$TMP" "$SETTINGS"; fi
      else
        rm -f "$TMP"
      fi
    fi
    [ -d "$CLAUDE_DIR/hooks/gitnexus" ] && run rm -rf "$CLAUDE_DIR/hooks/gitnexus"

    # 3. MCP entry
    DST_JSON="${config.home.homeDirectory}/.claude.json"
    [ -f "$DST_JSON" ] || { echo '{}' > "$DST_JSON"; chmod 600 "$DST_JSON"; }
    TMP="$(mktemp)"
    if $JQ --arg c "$GITNEXUS_BIN" '.mcpServers.gitnexus = {type: "stdio", command: $c, args: ["mcp"]}' "$DST_JSON" > "$TMP" 2>/dev/null; then
      if cmp -s "$TMP" "$DST_JSON"; then rm -f "$TMP"; else chmod 600 "$TMP"; mv "$TMP" "$DST_JSON"; fi
    else
      rm -f "$TMP"
    fi
  '';
}
