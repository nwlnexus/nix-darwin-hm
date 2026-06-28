#!/usr/bin/env bash
# mem0ctl — claude-mem decommission + mem0 enablement for dev hosts.
# Subcommands: disable-claude-mem | migrate | enable [--no-verify] | bootstrap
set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_MEM_DIR="${CLAUDE_MEM_DIR:-$HOME/.claude-mem}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS="$CLAUDE_DIR/settings.json"
INSTALLED="$CLAUDE_DIR/plugins/installed_plugins.json"
# shellcheck disable=SC2034  # used by enable (Task 5) and migrate (Task 6)
HOOK_DEST="$CLAUDE_DIR/hooks/mem0-recall-hook.sh"
# shellcheck disable=SC2034  # used by enable (Task 5) and migrate (Task 6)
RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # resources dir (siblings live here)
PROC_PATTERNS='worker-service\.cjs|claude-mem/.*/mcp-server\.cjs|chroma-mcp|uvx .*chroma-mcp'

log() { printf 'mem0ctl: %s\n' "$*" >&2; }

# Atomic jq edit; create {} if missing; leave file unchanged on jq error.
jq_inplace() {
  local file="$1"; shift
  local tmp; tmp="$(mktemp)"
  [ -s "$file" ] || printf '{}\n' > "$file"
  if jq "$@" "$file" > "$tmp" 2>/dev/null; then mv "$tmp" "$file"
  else rm -f "$tmp"; log "WARN: jq edit failed on $file (left unchanged)"; fi
}

kill_claude_mem() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local pids; pids="$(pgrep -f "$PROC_PATTERNS" || true)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 2
  pids="$(pgrep -f "$PROC_PATTERNS" || true)"
  # shellcheck disable=SC2086
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  return 0
}

disable_claude_mem() {
  log "stopping claude-mem processes…"
  kill_claude_mem

  log "disabling plugin across all layers…"
  jq_inplace "$SETTINGS" '.enabledPlugins["claude-mem@thedotmack"] = false'
  if [ -f "$CLAUDE_JSON" ]; then
    cp -f "$CLAUDE_JSON" "$CLAUDE_JSON.mem0ctl.bak"
    jq_inplace "$CLAUDE_JSON" 'walk(if type=="object"
      then with_entries(select(.key | test("claude-mem|thedotmack") | not)) else . end)'
  fi
  if [ -f "$INSTALLED" ]; then
    jq_inplace "$INSTALLED" 'walk(if type=="object"
      then with_entries(select(.key | test("claude-mem|thedotmack") | not)) else . end)'
  fi

  log "removing plugin cache…"
  rm -rf "$CLAUDE_DIR/plugins/cache/thedotmack"

  log "cleaning ~/.claude-mem live working set (keeping *.premem0-* + checkpoint)…"
  if [ -d "$CLAUDE_MEM_DIR" ]; then
    if ls "$CLAUDE_MEM_DIR"/*.premem0-* >/dev/null 2>&1; then
      rm -f "$CLAUDE_MEM_DIR"/claude-mem.db "$CLAUDE_MEM_DIR"/claude-mem.db-wal "$CLAUDE_MEM_DIR"/claude-mem.db-shm
      rm -rf "$CLAUDE_MEM_DIR"/chroma "$CLAUDE_MEM_DIR"/vector-db
    else
      log "WARN: no *.premem0-* backup — leaving claude-mem.db in place"
    fi
    rm -f "$CLAUDE_MEM_DIR"/worker.pid "$CLAUDE_MEM_DIR"/supervisor.json
  fi

  sleep 1
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "$PROC_PATTERNS" >/dev/null 2>&1; then
    log "WARN: claude-mem respawned — inspect $CLAUDE_JSON"
  else
    log "claude-mem disabled."
  fi
  return 0
}

migrate() { log "migrate: implemented in Task 6"; return 0; }
enable()  { log "enable: implemented in Task 5"; return 0; }

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    disable-claude-mem) disable_claude_mem "$@";;
    migrate)            migrate "$@";;
    enable)             enable "$@";;
    bootstrap)          disable_claude_mem; enable "$@";;
    *) echo "usage: mem0ctl {disable-claude-mem|migrate [--db PATH] [--mode smoke|full]|enable [--no-verify]|bootstrap}" >&2; return 2;;
  esac
}
main "$@"
