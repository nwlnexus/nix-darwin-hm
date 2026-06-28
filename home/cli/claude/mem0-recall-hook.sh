#!/usr/bin/env bash
# mem0-recall-hook.sh — SessionStart auto-recall for OpenMemory/Mem0 (fail-open).
# Resolves its sibling formatter whether installed as a nix-store symlink or
# copied into ~/.claude/hooks, then prints the SessionStart additionalContext
# JSON (or {"continue":true} on any error).
set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
MEM0_TOP_K="${MEM0_TOP_K:-3}"

fail_open() { printf '{"continue":true}\n'; exit 0; }

command -v python3 >/dev/null 2>&1 || fail_open
command -v curl    >/dev/null 2>&1 || fail_open

# Resolve the directory holding the formatter sibling.
src="${BASH_SOURCE[0]}"
hook_dir="$(cd "$(dirname "$src")" && pwd -P)"
if [ ! -f "$hook_dir/mem0_recall_format.py" ]; then
  resolved="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src" 2>/dev/null || true)"
  [ -n "$resolved" ] && hook_dir="$(cd "$(dirname "$resolved")" && pwd -P)"
fi
formatter="$hook_dir/mem0_recall_format.py"
[ -f "$formatter" ] || fail_open

# Read the hook stdin JSON and extract cwd (fall back to PWD).
stdin_data=""
if read -r -t 2 line 2>/dev/null; then stdin_data="$line"; fi
cwd="$(printf '%s' "$stdin_data" | python3 -c 'import sys,json
try:
    print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception:
    print("")' 2>/dev/null || true)"
cwd="${cwd:-${PWD:-}}"
[ -n "$cwd" ] || fail_open

body="$(python3 -c 'import json,sys
print(json.dumps({"user_id":sys.argv[1],"search_query":sys.argv[2],"page":1,"size":int(sys.argv[3])}))' \
  "$MEM0_USER_ID" "$cwd" "$MEM0_TOP_K" 2>/dev/null)" || fail_open

resp="$(curl -fsS --connect-timeout 1 --max-time 2 \
  -X POST -H 'Content-Type: application/json' -d "$body" \
  "$MEM0_URL/api/v1/memories/filter" 2>/dev/null)" || fail_open

printf '%s' "$resp" | MEM0_TOP_K="$MEM0_TOP_K" python3 "$formatter" "$cwd" 2>/dev/null || fail_open
