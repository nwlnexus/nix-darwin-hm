#!/usr/bin/env bash
# mem0-add.sh — resilient single write path to OpenMemory. Fail-open: on any
# error, spool the payload to the outbox and exit 0. Never fails the caller.
# Used by the mnemosyne worker (spawnMem0Add) and by mnemosyne-drain.sh replay.
set -eu
MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MNEMOSYNE_HOME="${MNEMOSYNE_HOME:-$HOME/.claude/mnemosyne}"
OUTBOX="$MNEMOSYNE_HOME/outbox"
payload="${1:-}"
[ -n "$payload" ] || exit 0

spool() {
  mkdir -p "$OUTBOX"
  h="$(printf '%s' "$payload" | shasum | cut -c1-40)"
  printf '%s' "$payload" > "$OUTBOX/$h.json"
  exit 0
}

curl -fsS --connect-timeout 2 --max-time 5 \
  -X POST -H 'Content-Type: application/json' -d "$payload" \
  "$MEM0_URL/api/v1/memories/" >/dev/null 2>&1 || spool
exit 0
