# home/cli/claude/default.nix
{
  pkgs,
  lib,
  config,
  ...
}:
{
  # /brain slash command (consult + ingest the second-brain wiki).
  home.file.".claude/commands/brain.md".source = ./commands/brain.md;

  home.sessionVariables = {
    SECOND_BRAIN_PATH = "${config.home.homeDirectory}/Documents/Obsidian Vault/brain";
  };

  # mnemosyne is retired. Its `install-hooks` wrote entries straight into
  # ~/.claude/settings.json and ~/.cursor/hooks.json (outside Nix), so nothing
  # removes them on its own — strip them on each activation until every host
  # has switched, then delete this block. Fail-soft: never blocks a switch.
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
  '';

  # gitnexus ships its own installer; it is idempotent and non-interactive.
  # gitnexus is a mise global (npm:gitnexus, see home/default.nix), not a
  # nixpkgs package, so it has no nix store path and isn't on the activation
  # script's PATH — resolve it by absolute path instead.
  #
  # The SHIM, not `installs/npm-gitnexus/latest/bin/gitnexus`: that install path
  # is a `#!/usr/bin/env node` script, and `node` is itself a mise global that is
  # NOT on the activation script's PATH either — so the old path failed with
  # `env: node: No such file or directory` and, being `|| true`, failed silently
  # on every rebuild. The shim is the mise binary itself and resolves its own
  # node. (modules/repomix/repomix.nix resolves both mise globals the same way.)
  # Fail-soft: a fresh host may not have the mise global installed yet.
  home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GITNEXUS_BIN="${config.home.homeDirectory}/.local/share/mise/shims/gitnexus"
    if [ -x "$GITNEXUS_BIN" ]; then
      "$GITNEXUS_BIN" setup -c claude || true
    fi
  '';
}
