#!/usr/bin/env bash
# mnemosyne-drain.sh — SessionStart hook (ordered BEFORE the recall hook).
# Kicks the extraction/drain worker in the background so it never blocks
# session start. Fail-open; always prints {"continue":true}.
#
# moneta is the sole memory sink (the mem0 dual-write is retired — mnemosyne
# feat/retire-mem0); the CLI's own drain replays the moneta outbox with
# confirmed-2xx-only deletion, so no replay logic lives here anymore.
set -eu
MNEMOSYNE_HOME="${MNEMOSYNE_HOME:-$HOME/.claude/mnemosyne}"
# moneta capture needs MONETA_AUTH_TOKEN + CF Access Service Auth from the
# personal secrets bundle (op-secrets → ~/projects/personal/.env).
PERSONAL_ENV="${PERSONAL_ENV:-$HOME/projects/personal/.env}"
if [ -f "$PERSONAL_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$PERSONAL_ENV"
  set +a
fi
emit() { printf '{"continue":true}\n'; exit 0; }

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
