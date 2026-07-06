#!/usr/bin/env bash
# mnemosyne-enqueue.sh — SessionEnd/PreCompact hook. Append a queue entry
# referencing the transcript so the drain worker can extract learnings later.
# No LLM, no network. Fail-open (always exit 0) — capture never breaks a session.
#
# NOTE: the event JSON is passed to python via an env var, NOT piped stdin.
# `python3 - <<'PY'` makes the heredoc python's stdin (the program itself), so
# json.load(sys.stdin) would read the program, not the event — a subtle pitfall.
set -eu
MNEMOSYNE_HOME="${MNEMOSYNE_HOME:-$HOME/.claude/mnemosyne}"
QUEUE="$MNEMOSYNE_HOME/queue"
event="$(cat 2>/dev/null || true)"
MNEMO_EVENT="$event" MNEMO_QUEUE="$QUEUE" python3 - <<'PY' 2>/dev/null || true
import json, os, time
queue = os.environ.get("MNEMO_QUEUE", "")
try:
    data = json.loads(os.environ.get("MNEMO_EVENT", ""))
except Exception:
    raise SystemExit(0)
tp = data.get("transcript_path")
sid = data.get("session_id") or "unknown"
if not tp:
    raise SystemExit(0)
os.makedirs(queue, exist_ok=True)
stamp = time.strftime("%Y%m%dT%H%M%S")
entry = {
    "transcript": tp,
    "session": sid,
    "cwd": data.get("cwd") or "",
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(os.path.join(queue, f"{stamp}-{sid}.json"), "w") as f:
    json.dump(entry, f)
PY
exit 0
