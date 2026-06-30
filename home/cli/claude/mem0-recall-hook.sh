#!/usr/bin/env bash
# mem0-recall-hook.sh — SessionStart auto-recall for OpenMemory/Mem0 (fail-open).
# Resolves its sibling formatter whether installed as a nix-store symlink or
# copied into ~/.claude/hooks, then prints the SessionStart additionalContext
# JSON (or {"continue":true} on any error).
set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
MEM0_TOP_K="${MEM0_TOP_K:-5}"

# Breadcrumbs go to stderr: shown in the hook transcript / debug for
# diagnosis, but never added to the model's context (only stdout is).
log() { printf 'mem0-recall: %s\n' "$*" >&2; }

# Silent fail-open: structural problems the session can't act on. Log the
# reason so the hook is debuggable, but emit no model-visible context.
fail_open() { log "fail-open: ${1:-unspecified}"; printf '{"continue":true}\n'; exit 0; }

# Visible fail-open: the endpoint was unreachable (vs. genuinely empty), so
# surface a short note rather than letting the session assume no memories exist.
emit_unavailable() {
  log "unavailable: ${1:-endpoint unreachable}"
  python3 "$formatter" --unavailable "$MEM0_URL" 2>/dev/null || printf '{"continue":true}\n'
  exit 0
}

command -v python3 >/dev/null 2>&1 || fail_open "python3 not on PATH"
command -v curl    >/dev/null 2>&1 || fail_open "curl not on PATH"

# Resolve the directory holding the formatter sibling.
src="${BASH_SOURCE[0]}"
hook_dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)" || fail_open "cannot resolve hook dir"
if [ ! -f "$hook_dir/mem0_recall_format.py" ]; then
  resolved="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src" 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    hook_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)" || fail_open "cannot resolve symlink target dir"
  fi
fi
formatter="$hook_dir/mem0_recall_format.py"
[ -f "$formatter" ] || fail_open "formatter not found beside hook"

# Read the hook stdin JSON and extract cwd (fall back to PWD).
# Read the WHOLE payload regardless of a trailing newline: `read` returns
# nonzero at EOF-without-delimiter but still populates the variable, so capture
# it with `|| true` rather than gating assignment on the exit status. The old
# `if read -r line` form dropped newline-less payloads, silently falling back to
# $PWD — which recalls the wrong project whenever PWD != the cwd field.
stdin_data=""
IFS= read -r -t 2 -d '' stdin_data 2>/dev/null || true
cwd="$(printf '%s' "$stdin_data" | python3 -c 'import sys,json
try:
    print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception:
    print("")' 2>/dev/null || true)"
cwd="${cwd:-${PWD:-}}"
[ -n "$cwd" ] || fail_open "no cwd in stdin or PWD"

body="$(python3 -c 'import json,sys
print(json.dumps({"user_id":sys.argv[1],"search_query":sys.argv[2],"page":1,"size":int(sys.argv[3])}))' \
  "$MEM0_USER_ID" "$cwd" "$MEM0_TOP_K" 2>/dev/null)" || fail_open "request body build failed"

# Endpoint problems (off-tailnet, timeout, non-2xx) are surfaced via
# emit_unavailable; a reachable-but-empty result stays silent in the formatter.
resp="$(curl -fsS --connect-timeout 1 --max-time 2 \
  -X POST -H 'Content-Type: application/json' -d "$body" \
  "$MEM0_URL/api/v1/memories/filter" 2>/dev/null)" || emit_unavailable "curl failed against $MEM0_URL"

printf '%s' "$resp" | MEM0_TOP_K="$MEM0_TOP_K" python3 "$formatter" "$cwd" 2>/dev/null || fail_open "formatter errored on response"
