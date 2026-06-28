#!/usr/bin/env bash
# Shell tests for mem0ctl — isolated temp HOME, jq + bash only.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM0CTL="$SELF/../mem0ctl.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

setup() {
  TMP="$(mktemp -d)"
  export CLAUDE_DIR="$TMP/.claude" CLAUDE_MEM_DIR="$TMP/.claude-mem" CLAUDE_JSON="$TMP/.claude.json"
  mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/plugins/cache/thedotmack/claude-mem/13.8.1" "$CLAUDE_MEM_DIR/chroma"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/existing/other-hook.sh"}]}]},"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true}}' > "$CLAUDE_DIR/settings.json"
  printf '{"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true},"mcpServers":{"claude-mem":{"x":1},"other":{"y":2}}}' > "$CLAUDE_JSON"
  printf '{}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
  : > "$CLAUDE_MEM_DIR/claude-mem.db"
  : > "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627"
}
teardown() { rm -rf "$TMP"; }

# --- disable-claude-mem: full teardown, keep backup ---
setup
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
dis="$(jq '.enabledPlugins["claude-mem@thedotmack"]' "$CLAUDE_DIR/settings.json")"
keep="$(jq '.enabledPlugins["keep@me"]' "$CLAUDE_DIR/settings.json")"
cj_cm="$(jq '.mcpServers | has("claude-mem")' "$CLAUDE_JSON")"
cj_other="$(jq '.mcpServers | has("other")' "$CLAUDE_JSON")"
cache_gone=$([ ! -d "$CLAUDE_DIR/plugins/cache/thedotmack" ] && echo true || echo false)
db_gone=$([ ! -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && echo true || echo false)
backup_kept=$([ -f "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627" ] && echo true || echo false)
{ [ "$dis" = false ] && [ "$keep" = true ] && [ "$cj_cm" = false ] && [ "$cj_other" = true ] \
  && [ "$cache_gone" = true ] && [ "$db_gone" = true ] && [ "$backup_kept" = true ]; } \
  && ok "disable tears down all layers, keeps backup" \
  || no "disable teardown (dis=$dis keep=$keep cm=$cj_cm other=$cj_other cache=$cache_gone db=$db_gone backup=$backup_kept)"
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1 && ok "disable idempotent" || no "disable idempotent (nonzero)"
teardown

# --- guard: no backup => live DB preserved ---
setup
rm -f "$CLAUDE_MEM_DIR"/*.premem0-*
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
[ -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && ok "no-backup guard keeps live DB" || no "no-backup guard keeps live DB"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
