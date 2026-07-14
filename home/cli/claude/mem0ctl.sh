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
HOOK_DEST="$CLAUDE_DIR/hooks/moneta-recall-hook.sh"
DRAIN_DEST="$CLAUDE_DIR/hooks/mnemosyne-drain.sh"       # SessionStart (before recall)
ENQUEUE_DEST="$CLAUDE_DIR/hooks/mnemosyne-enqueue.sh"   # SessionEnd + PreCompact
RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # resources dir (siblings live here)
PROC_PATTERNS='claude-mem/[^/]+/scripts/worker-service\.cjs|claude-mem/[^/]+/scripts/mcp-server\.cjs|chroma-mcp.*\.claude-mem'

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
    [ -f "$CLAUDE_JSON.mem0ctl.bak" ] || cp "$CLAUDE_JSON" "$CLAUDE_JSON.mem0ctl.bak"
    jq_inplace "$CLAUDE_JSON" 'walk(if type=="object"
      then with_entries(select(.key | test("^claude-mem([@:].*)?$|@thedotmack$") | not)) else . end)'
  fi
  if [ -f "$INSTALLED" ]; then
    jq_inplace "$INSTALLED" 'walk(if type=="object"
      then with_entries(select(.key | test("^claude-mem([@:].*)?$|@thedotmack$") | not)) else . end)'
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

migrate() {
  local db="" mode="full" conc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --db)          db="$2"; shift 2;;
      --mode)        mode="$2"; shift 2;;
      --concurrency) conc="$2"; shift 2;;
      *) log "unknown migrate arg: $1"; return 2;;
    esac
  done
  if [ -z "$db" ]; then
    # shellcheck disable=SC2010
    db="$(ls -t "$CLAUDE_MEM_DIR"/*.premem0-* 2>/dev/null | grep -vE '\-(wal|shm)$' | head -1 || true)"
  fi
  [ -n "$db" ] && [ -f "$db" ] || { log "no migration DB found (pass --db PATH)"; return 1; }
  command -v uv >/dev/null 2>&1 || { log "uv not found on PATH"; return 1; }
  local ckpt="$CLAUDE_MEM_DIR/mem0-migrate-checkpoint.json"
  log "migrating $db → $MEM0_URL (mode=$mode, checkpoint=$ckpt)…"
  # Run in an ephemeral uv env (--no-project) importing the tool from the
  # read-only nix store via PYTHONPATH. Project mode would try to create a
  # .venv inside the store and fail (read-only). Matches the tool's README.
  PYTHONPATH="$RES/mem0-migrate/src" uv run --no-project --with httpx \
    python -m mem0_migrate.run \
    --db "$db" --url "$MEM0_URL" --user-id "$MEM0_USER_ID" --mode "$mode" \
    --checkpoint "$ckpt" ${conc:+--concurrency "$conc"}
}

enable() {
  local verify=1
  [ "${1:-}" = "--no-verify" ] && verify=0

  # Install hook for ad-hoc (non-nix) hosts; skip if already a nix-store symlink.
  if [ -L "$HOOK_DEST" ] && readlink "$HOOK_DEST" | grep -q '/nix/store/'; then
    log "recall hook is nix-managed — skipping copy"
  else
    mkdir -p "$(dirname "$HOOK_DEST")"
    cp "$RES/moneta-recall-hook.sh"   "$HOOK_DEST"
    cp "$RES/moneta_recall_format.py" "$(dirname "$HOOK_DEST")/moneta_recall_format.py"
    chmod +x "$HOOK_DEST"
    log "installed recall hook → $HOOK_DEST"
  fi

  # Keyed replace-or-skip merge of the SessionStart recall group.
  # shellcheck disable=SC2016  # $cmd is a jq variable, not a shell variable
  jq_inplace "$SETTINGS" --arg cmd "$HOOK_DEST" '
    .hooks //= {} | .hooks.SessionStart //= [] |
    .hooks.SessionStart |=
      ( map(select(any(.hooks[]?; (.command // "") | endswith("moneta-recall-hook.sh") or endswith("mem0-recall-hook.sh")) | not))
        + [ { hooks: [ { type: "command", command: $cmd, timeout: 12 } ] } ] )'
  log "wired SessionStart recall hook into settings.json"

  # --- mnemosyne capture hooks (drain + enqueue) ---
  # Install for ad-hoc (non-nix) hosts; skip files already nix-store symlinks.
  for pair in "mnemosyne-drain.sh:$DRAIN_DEST" "mnemosyne-enqueue.sh:$ENQUEUE_DEST"; do
    src="${pair%%:*}"; dest="${pair##*:}"
    if [ -L "$dest" ] && readlink "$dest" | grep -q '/nix/store/'; then
      log "$src is nix-managed — skipping copy"
    else
      mkdir -p "$(dirname "$dest")"
      cp "$RES/$src" "$dest"; chmod +x "$dest"
      log "installed $src → $dest"
    fi
  done

  # SessionStart: prepend the drain group so it runs BEFORE recall (keyed
  # replace-or-skip keeps it idempotent).
  # shellcheck disable=SC2016  # $cmd is a jq variable, not a shell variable
  jq_inplace "$SETTINGS" --arg cmd "$DRAIN_DEST" '
    .hooks //= {} | .hooks.SessionStart //= [] |
    .hooks.SessionStart |=
      ( [ { hooks: [ { type: "command", command: $cmd, timeout: 10 } ] } ]
        + map(select(any(.hooks[]?; (.command // "") | endswith("mnemosyne-drain.sh")) | not)) )'

  # SessionEnd + PreCompact: append the enqueue group (keyed replace-or-skip).
  for evt in SessionEnd PreCompact; do
    # shellcheck disable=SC2016  # $cmd/$evt are jq variables, not shell variables
    jq_inplace "$SETTINGS" --arg cmd "$ENQUEUE_DEST" --arg evt "$evt" '
      .hooks //= {} | .hooks[$evt] //= [] |
      .hooks[$evt] |=
        ( map(select(any(.hooks[]?; (.command // "") | endswith("mnemosyne-enqueue.sh")) | not))
          + [ { hooks: [ { type: "command", command: $cmd } ] } ] )'
  done
  log "wired mnemosyne drain (SessionStart) + enqueue (SessionEnd, PreCompact) into settings.json"

  if [ "$verify" -eq 1 ]; then
    if curl -fsS --connect-timeout 1 --max-time 2 \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"user_id\":\"$MEM0_USER_ID\",\"search_query\":\"healthcheck\",\"page\":1,\"size\":1}" \
         "$MEM0_URL/api/v1/memories/filter" >/dev/null 2>&1; then
      log "mem0 reachable at $MEM0_URL"
    else
      log "WARN: mem0 not reachable at $MEM0_URL (off-tailnet?) — hook will fail-open"
    fi
  fi
  return 0
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    disable-claude-mem) disable_claude_mem "$@";;
    migrate)            migrate "$@";;
    enable)             enable "$@";;
    bootstrap)          disable_claude_mem; enable "$@";;
    *) echo "usage: mem0ctl {disable-claude-mem|migrate [--db PATH] [--mode smoke|full] [--concurrency N]|enable [--no-verify]|bootstrap}" >&2; return 2;;
  esac
}
main "$@"
