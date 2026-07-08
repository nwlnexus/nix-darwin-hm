#!/usr/bin/env bash
# mnemosyne-drain.sh — SessionStart hook (ordered BEFORE the recall hook).
# Replays the mem0 outbox, then kicks the extraction worker in the background
# so it never blocks session start. Fail-open; always prints {"continue":true}.
#
# Outbox replay is a DIRECT POST (not via mem0-add.sh): mem0-add.sh always
# exits 0 and re-spools on failure, so it cannot signal success/failure for
# replay. We remove a spooled entry only on a confirmed HTTP 2xx; on failure
# the file is left in place for the next drain.
set -eu
MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MNEMOSYNE_HOME="${MNEMOSYNE_HOME:-$HOME/.claude/mnemosyne}"
OUTBOX="$MNEMOSYNE_HOME/outbox"
emit() { printf '{"continue":true}\n'; exit 0; }

if [ -d "$OUTBOX" ]; then
  for f in "$OUTBOX"/*.json; do
    [ -e "$f" ] || continue
    if curl -fsS --connect-timeout 2 --max-time 5 \
         -X POST -H 'Content-Type: application/json' -d @"$f" \
         "$MEM0_URL/api/v1/memories/" >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
fi

# Kick the worker without blocking session start. Guard against a missing /
# non-runnable CLI: if `mnemosyne` isn't on PATH the drain would fail silently,
# so surface a visible breadcrumb to stderr (the hook transcript) instead.
# On success, background it but tee its stderr to a log so a dead worker
# surfaces rather than vanishing into /dev/null.
if command -v mnemosyne >/dev/null 2>&1; then
  DRAIN_LOG="$MNEMOSYNE_HOME/drain.log"
  mkdir -p "$MNEMOSYNE_HOME"
  nohup mnemosyne drain >/dev/null 2>>"$DRAIN_LOG" &
else
  printf 'mnemosyne-drain: CLI not found on PATH — queue not drained\n' >&2
fi
emit
