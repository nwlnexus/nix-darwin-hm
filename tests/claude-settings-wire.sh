#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/settings-wire.sh (the activation script that unions the nix-owned allow rules
# into .permissions.allow and sets .autoMode in each Claude dir's settings.json). Runs on temp files only, with
# made-up rules and autoMode values.
#   bash tests/claude-settings-wire.sh        (needs bash, jq, cmp; `just test-claude-settings-wire`)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SETTINGS_WIRE:-$here/../home/cli/claude/settings-wire.sh}"
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
wire() { # allow.json auto-mode.json|- settings...
  bash -euo pipefail "$script" "$@"
}
jqe() { jq -e "$@" >/dev/null; } # filter file
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

allow="$tmp/allow.json"
printf '["Bash(gh pr create *)", "Bash(gh run *)", "Bash(git push -u origin *)"]\n' >"$allow"
auto1="$tmp/auto1.json"
printf '{"allow": ["$defaults", "rule one"], "environment": ["**Example**: one"]}\n' >"$auto1"
auto2="$tmp/auto2.json"
printf '{"allow": ["rule two"], "environment": ["**Example**: two", "**Host containment**: test"]}\n' >"$auto2"

# 1. union: missing rules appended in order, existing ones (ours and foreign) kept, other keys untouched
s="$tmp/a/settings.json"
mkdir -p "$tmp/a"
cat >"$s" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls)", "Bash(gh run *)"], "deny": ["Read(./.env)"], "defaultMode": "auto"},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/other-stop"}]}]},
  "autoMode": {"allow": ["old"], "environment": ["old env"], "extra": true}
}
JSON
chmod 0600 "$s"
wire "$allow" "$auto1" "$s" 2>/dev/null
check "valid JSON afterwards" jqe . "$s"
check "union: foreign rules kept first, missing ones appended in order" \
  jqe '.permissions.allow == ["Bash(ls)", "Bash(gh run *)", "Bash(gh pr create *)", "Bash(git push -u origin *)"]' "$s"
check "no duplicates" jqe '.permissions.allow | length == (unique | length)' "$s"
check "other permission keys untouched" jqe '.permissions.deny == ["Read(./.env)"] and .permissions.defaultMode == "auto"' "$s"
check "autoMode replaced as a whole" jqe --slurpfile a "$auto1" '.autoMode == $a[0]' "$s"
check "other keys untouched" jqe '.model == "opus" and .hooks.Stop[0].hooks[0].command == "/usr/bin/other-stop"' "$s"
check "mode kept (0600)" [ "$(mode "$s")" = 600 ]

# 2. idempotent: second run writes nothing and says nothing
before="$(cksum <"$s")"
out="$(wire "$allow" "$auto1" "$s" 2>&1)"
check "second run prints nothing" [ -z "$out" ]
check "second run leaves file unchanged" [ "$(cksum <"$s")" = "$before" ]

# 3. never removes: a rule added by hand later, and a rule dropped from the list, both stay
jq '.permissions.allow += ["Bash(hand added)"]' "$s" >"$s.new" && mv "$s.new" "$s"
printf '["Bash(gh pr create *)"]\n' >"$tmp/allow-short.json"
wire "$tmp/allow-short.json" "$auto1" "$s" 2>/dev/null
check "nothing removed when the list shrinks" \
  jqe '.permissions.allow == ["Bash(ls)", "Bash(gh run *)", "Bash(gh pr create *)", "Bash(git push -u origin *)", "Bash(hand added)"]' "$s"

# 4. a new autoMode replaces the old one; `-` leaves it alone
wire "$allow" "$auto2" "$s" 2>/dev/null
check "autoMode replaced by the new source" jqe --slurpfile a "$auto2" '.autoMode == $a[0]' "$s"
jq '.autoMode.environment += ["hand edit"]' "$s" >"$s.new" && mv "$s.new" "$s"
wire "$allow" - "$s" 2>/dev/null
check "'-' leaves autoMode alone" jqe '.autoMode.environment[-1] == "hand edit"' "$s"

# 5. missing file and missing dir: created with {} plus our keys
s3="$tmp/c/new/settings.json"
wire "$allow" "$auto1" "$s3" 2>/dev/null
check "missing file created" jqe --slurpfile a "$auto1" --slurpfile l "$allow" \
  '(keys == ["autoMode", "permissions"]) and .permissions == {allow: $l[0]} and .autoMode == $a[0]' "$s3"
s3b="$tmp/c2/settings.json"
wire "$allow" - "$s3b" 2>/dev/null
check "missing file without autoMode source: no autoMode key" jqe 'keys == ["permissions"]' "$s3b"

# 6. unparseable settings.json is left byte for byte, exit status 0
s4="$tmp/d/settings.json"
mkdir -p "$tmp/d"
printf '{ not json' >"$s4"
cp "$s4" "$tmp/d.orig"
wire "$allow" "$auto1" "$s4" 2>/dev/null
rc=$?
check "bad JSON: exit 0" [ "$rc" = 0 ]
check "bad JSON: file untouched" cmp -s "$s4" "$tmp/d.orig"

# 7. permissions.allow of the wrong type: reported, untouched
s5="$tmp/e/settings.json"
mkdir -p "$tmp/e"
printf '{"permissions": {"allow": "oops"}}\n' >"$s5"
cp "$s5" "$tmp/e.orig"
wire "$allow" "$auto1" "$s5" 2>/dev/null
check "wrong-typed allow: file untouched" cmp -s "$s5" "$tmp/e.orig"

# 8. bad inputs: nothing is written, exit 0
s6="$tmp/f/settings.json"
mkdir -p "$tmp/f"
printf '{}\n' >"$s6"
printf '{"not": "an array"}\n' >"$tmp/allow-bad.json"
wire "$tmp/allow-bad.json" "$auto1" "$s6" 2>/dev/null
rc=$?
check "bad allow list: exit 0, file untouched" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "{}" ]' _ "$rc" "$s6"
printf '[1, 2]\n' >"$tmp/auto-bad.json"
wire "$allow" "$tmp/auto-bad.json" "$s6" 2>/dev/null
rc=$?
check "bad autoMode source: exit 0, file untouched" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "{}" ]' _ "$rc" "$s6"

# 9. several files in one call
s7="$tmp/g/settings.json"
mkdir -p "$tmp/g"
printf '{}\n' >"$s7"
wire "$allow" "$auto1" "$s6" "$s7" 2>/dev/null
check "both files wired" bash -c 'jq -e ".permissions.allow | length == 3" "$1" >/dev/null && jq -e ".permissions.allow | length == 3" "$2" >/dev/null' _ "$s6" "$s7"

# 10. usage errors exit 2
bash "$script" "$allow" - >/dev/null 2>&1
check "too few arguments: exit 2" [ "$?" = 2 ]

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
