#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/hook-wire.sh (the activation script that keeps the progress-stale Stop hook
# entry in each Claude dir's settings.json). Runs on temp files only.
#   bash tests/claude-hook-wire.sh            (needs bash, jq, cmp; `just test-claude-hook-wire`)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${HOOK_WIRE:-$here/../home/cli/claude/hook-wire.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # name, command...
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
wire() { # command settings...
  local cmd="$1"
  shift
  bash -euo pipefail "$script" Stop '*' 'progress-stale\.sh' "$cmd" "$@"
}
jqe() { jq -e "$@" >/dev/null; } # filter file
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

cmd1=/nix/store/aaa-agent-skills/hooks/progress-stale.sh
cmd2=/home/u/.claude-personal/hooks/progress-stale.sh

# 1. settings.json with foreign keys, a foreign Stop hook and another event: only ours is added
s="$tmp/a/settings.json"
mkdir -p "$tmp/a"
cat >"$s" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls)"]},
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/other-stop"}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "memory-session-start"}]}]
  }
}
JSON
chmod 0600 "$s"
cp "$s" "$tmp/a.orig"
wire "$cmd1" "$s" 2>/dev/null
check "valid JSON afterwards" jqe . "$s"
check "foreign Stop hook kept first" jqe '.hooks.Stop[0].hooks[0].command == "/usr/bin/other-stop"' "$s"
check "our Stop entry appended with matcher *" jqe --arg c "$cmd1" '.hooks.Stop[1] == {matcher: "*", hooks: [{type: "command", command: $c}]}' "$s"
check "two Stop groups" jqe '.hooks.Stop | length == 2' "$s"
check "other keys untouched" jqe '.model == "opus" and .permissions.allow == ["Bash(ls)"] and .hooks.SessionStart[0].hooks[0].command == "memory-session-start"' "$s"
check "mode kept (0600)" [ "$(mode "$s")" = 600 ]

# 2. idempotent: second run writes nothing and says nothing
before="$(cksum <"$s")"
out="$(wire "$cmd1" "$s" 2>&1)"
check "second run prints nothing" [ -z "$out" ]
check "second run leaves file unchanged" [ "$(cksum <"$s")" = "$before" ]

# 3. a new store path replaces ours in place, not doubled
wire "$cmd2" "$s" 2>/dev/null
check "still two Stop groups" jqe '.hooks.Stop | length == 2' "$s"
check "command replaced" jqe --arg c "$cmd2" '.hooks.Stop[1].hooks[0].command == $c' "$s"
check "foreign hook still first" jqe '.hooks.Stop[0].hooks[0].command == "/usr/bin/other-stop"' "$s"

# 4. our entry in the middle stays in its slot; a group mixing ours and a foreign hook keeps the foreign hook
s2="$tmp/b/settings.json"
mkdir -p "$tmp/b"
cat >"$s2" <<JSON
{"hooks": {"Stop": [
  {"hooks": [{"type": "command", "command": "first"}]},
  {"hooks": [{"type": "command", "command": "$cmd1"}, {"type": "command", "command": "mixed-foreign"}]},
  {"hooks": [{"type": "command", "command": "last"}]},
  {"hooks": [{"type": "command", "command": "$cmd1"}]}
]}}
JSON
wire "$cmd2" "$s2" 2>/dev/null
check "mixed group keeps the foreign hook" jqe '[.hooks.Stop[].hooks[].command] | index("mixed-foreign") != null' "$s2"
check "exactly one of our hooks" jqe '[.hooks.Stop[].hooks[] | select(.command | test("progress-stale"))] | length == 1' "$s2"
check "order preserved (first, mixed, ours, last)" jqe --arg c "$cmd2" '[.hooks.Stop[] | .hooks[0].command] == ["first", "mixed-foreign", $c, "last"]' "$s2"

# 5. missing file and missing dir: created with {} plus our entry
s3="$tmp/c/new/settings.json"
wire "$cmd1" "$s3" 2>/dev/null
check "missing file created" jqe --arg c "$cmd1" '.hooks.Stop == [{matcher: "*", hooks: [{type: "command", command: $c}]}] and (keys == ["hooks"])' "$s3"

# 6. unparseable settings.json is left byte for byte, exit status 0
s4="$tmp/d/settings.json"
mkdir -p "$tmp/d"
printf '{ not json' >"$s4"
cp "$s4" "$tmp/d.orig"
wire "$cmd1" "$s4" 2>/dev/null
rc=$?
check "bad JSON: exit 0" [ "$rc" = 0 ]
check "bad JSON: file untouched" cmp -s "$s4" "$tmp/d.orig"

# 7. hooks of the wrong type: reported, untouched
s5="$tmp/e/settings.json"
mkdir -p "$tmp/e"
printf '{"hooks": {"Stop": "oops"}}\n' >"$s5"
cp "$s5" "$tmp/e.orig"
wire "$cmd1" "$s5" 2>/dev/null
check "wrong-typed Stop: file untouched" cmp -s "$s5" "$tmp/e.orig"

# 8. several files in one call
s6="$tmp/f/settings.json"
s7="$tmp/g/settings.json"
mkdir -p "$tmp/f" "$tmp/g"
printf '{}\n' >"$s6"
printf '{}\n' >"$s7"
wire "$cmd1" "$s6" "$s7" 2>/dev/null
check "both files wired" bash -c 'jq -e ".hooks.Stop | length == 1" "$1" >/dev/null && jq -e ".hooks.Stop | length == 1" "$2" >/dev/null' _ "$s6" "$s7"

# 9. usage errors exit 2
bash "$script" Stop '*' x >/dev/null 2>&1
check "too few arguments: exit 2" [ "$?" = 2 ]

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
