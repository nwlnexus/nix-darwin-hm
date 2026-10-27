#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/telemetry-wire.sh (the activation script that sets the nix-owned telemetry
# keys in a Claude dir's settings.json `env`). Runs on temp files only, with made-up values.
#   bash tests/claude-telemetry-wire.sh        (needs bash, jq, cmp; `just test-claude-telemetry-wire`)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${TELEMETRY_WIRE:-$here/../home/cli/claude/telemetry-wire.sh}"
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
wire() { bash -euo pipefail "$script" "$@"; }
jqe() { jq -e "$@" >/dev/null; } # filter file
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

env1="$tmp/env1.json"
printf '{"CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.example:4317", "OTEL_RESOURCE_ATTRIBUTES": "account=personal"}\n' >"$env1"
env2="$tmp/env2.json"
printf '{"CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_EXPORTER_OTLP_ENDPOINT": "http://other.example:4317", "OTEL_RESOURCE_ATTRIBUTES": "account=work"}\n' >"$env2"

# 1. our keys set, a foreign env entry and every other key kept, a stale value of ours replaced
s="$tmp/a/settings.json"
mkdir -p "$tmp/a"
cat >"$s" <<'JSON'
{
  "model": "opus",
  "env": {"FOO": "bar", "OTEL_RESOURCE_ATTRIBUTES": "account=stale"},
  "permissions": {"allow": ["Bash(ls)"]},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/other-stop"}]}]}
}
JSON
chmod 0600 "$s"
wire "$env1" "$s" 2>/dev/null
check "valid JSON afterwards" jqe . "$s"
check "our keys set" jqe --slurpfile e "$env1" '.env | to_entries | map(select(.key != "FOO")) | from_entries == $e[0]' "$s"
check "foreign env entry kept" jqe '.env.FOO == "bar"' "$s"
check "other keys untouched" jqe '.model == "opus" and .permissions.allow == ["Bash(ls)"] and .hooks.Stop[0].hooks[0].command == "/usr/bin/other-stop"' "$s"
check "mode kept (0600)" [ "$(mode "$s")" = 600 ]

# 2. idempotent
before="$(cksum <"$s")"
out="$(wire "$env1" "$s" 2>&1)"
check "second run prints nothing" [ -z "$out" ]
check "second run leaves file unchanged" [ "$(cksum <"$s")" = "$before" ]

# 3. a changed value is replaced (account differs per dir)
wire "$env2" "$s" 2>/dev/null
check "changed value replaced" jqe '.env.OTEL_RESOURCE_ATTRIBUTES == "account=work" and .env.OTEL_EXPORTER_OTLP_ENDPOINT == "http://other.example:4317" and .env.FOO == "bar"' "$s"

# 4. missing file and dir: created with {} plus our env
s2="$tmp/b/new/settings.json"
wire "$env1" "$s2" 2>/dev/null
check "missing file created" jqe --slurpfile e "$env1" 'keys == ["env"] and .env == $e[0]' "$s2"

# 5. unparseable settings.json left byte for byte, exit 0
s3="$tmp/c/settings.json"
mkdir -p "$tmp/c"
printf '{ not json' >"$s3"
cp "$s3" "$tmp/c.orig"
wire "$env1" "$s3" 2>/dev/null
rc=$?
check "bad JSON: exit 0" [ "$rc" = 0 ]
check "bad JSON: file untouched" cmp -s "$s3" "$tmp/c.orig"

# 6. env of the wrong type: reported, untouched
s4="$tmp/d/settings.json"
mkdir -p "$tmp/d"
printf '{"env": "oops"}\n' >"$s4"
cp "$s4" "$tmp/d.orig"
wire "$env1" "$s4" 2>/dev/null
check "wrong-typed env: file untouched" cmp -s "$s4" "$tmp/d.orig"

# 7. bad env source: nothing written, exit 0
s5="$tmp/e/settings.json"
mkdir -p "$tmp/e"
printf '{}\n' >"$s5"
printf '{"A": 1}\n' >"$tmp/env-bad.json"
wire "$tmp/env-bad.json" "$s5" 2>/dev/null
rc=$?
check "non-string env value: exit 0, file untouched" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "{}" ]' _ "$rc" "$s5"

# 8. usage errors exit 2
bash "$script" "$env1" >/dev/null 2>&1
check "too few arguments: exit 2" [ "$?" = 2 ]

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
