#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/plugin-wire.sh (the activation script that declares the plugin marketplaces
# and enabled plugins in each Claude dir's settings.json and removes the old nix harness hook entries). Runs on temp
# files only.
#   bash tests/claude-plugin-wire.sh          (needs bash, jq, cmp; `just test-claude-plugin-wire`)
# shellcheck disable=SC2016  # test helpers quote bash -c bodies on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${PLUGIN_WIRE:-$here/../home/cli/claude/plugin-wire.sh}"
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

ps=/home/u/.claude-personal/hooks/progress-stale.sh
pd=/home/u/.claude-personal/hooks/permission-denied-log.sh
personal="$tmp/personal.json"
cat >"$personal" <<JSON
{
  "marketplaces": {
    "nwlnexus": {"source": {"source": "github", "repo": "nwlnexus/agent-plugins"}, "autoUpdate": true},
    "olympus-private": {"source": {"source": "github", "repo": "nwlnexus/olympus-memory"}, "autoUpdate": true}
  },
  "enable": {"agent-harness@nwlnexus": true, "olympus-memory@olympus-private": true},
  "removeHookCommands": ["$ps", "$pd"]
}
JSON
work="$tmp/work.json"
cat >"$work" <<'JSON'
{
  "marketplaces": {"nwlnexus": {"source": {"source": "github", "repo": "nwlnexus/agent-plugins"}, "autoUpdate": true}},
  "enable": {"agent-harness@nwlnexus": true},
  "removeHookCommands": []
}
JSON

# 1. existing settings with old harness hooks and foreign entries
s="$tmp/a/settings.json"
mkdir -p "$tmp/a"
cat >"$s" <<JSON
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls)"]},
  "enabledPlugins": {"foo@bar": true, "agent-harness@nwlnexus": false},
  "extraKnownMarketplaces": {"bar": {"source": {"source": "github", "repo": "x/bar"}}},
  "hooks": {
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "$ps"}]},
      {"hooks": [{"type": "command", "command": "/other/stop.sh"}]}
    ],
    "PermissionDenied": [{"matcher": "*", "hooks": [{"type": "command", "command": "$pd"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "/x/progress-stale.sh"}, {"type": "command", "command": "$ps"}]}]
  }
}
JSON
chmod 0600 "$s"
wire "$personal" "$s" 2>/dev/null
check "marketplaces declared" jqe '.extraKnownMarketplaces.nwlnexus.source.repo == "nwlnexus/agent-plugins" and .extraKnownMarketplaces.nwlnexus.autoUpdate == true and .extraKnownMarketplaces."olympus-private".source.repo == "nwlnexus/olympus-memory"' "$s"
check "plugins enabled" jqe '.enabledPlugins."agent-harness@nwlnexus" == true and .enabledPlugins."olympus-memory@olympus-private" == true' "$s"
check "foreign marketplace and plugin kept" jqe '.extraKnownMarketplaces.bar and .enabledPlugins."foo@bar" == true' "$s"
check "other keys kept" jqe '.model == "opus" and .permissions.allow == ["Bash(ls)"]' "$s"
check "old Stop hook removed, foreign Stop kept" jqe '.hooks.Stop == [{"hooks": [{"type": "command", "command": "/other/stop.sh"}]}]' "$s"
check "emptied event removed" jqe '.hooks | has("PermissionDenied") | not' "$s"
check "mixed group keeps the foreign hook" jqe '.hooks.SessionStart == [{"hooks": [{"type": "command", "command": "/x/progress-stale.sh"}]}]' "$s"
check "mode kept" [ "$(mode "$s")" = 600 ]

# 2. idempotent
cp "$s" "$tmp/a.before"
out=$(wire "$personal" "$s" 2>&1)
check "second run is a no-op" bash -c 'cmp -s "$1" "$2" && [ -z "$3" ]' _ "$s" "$tmp/a.before" "$out"

# 3. work spec: only the public marketplace and plugin; hooks of only ours -> .hooks dropped
w="$tmp/w/settings.json"
mkdir -p "$tmp/w"
printf '{"hooks": {}}\n' >"$w"
wire "$work" "$w" 2>/dev/null
check "work: public only" jqe '(.extraKnownMarketplaces | keys) == ["nwlnexus"] and .enabledPlugins == {"agent-harness@nwlnexus": true}' "$w"
check "work: no private name" bash -c '! grep -q olympus "$1"' _ "$w"
check "work: empty hooks object left as it was" jqe '.hooks == {}' "$w"

o="$tmp/o/settings.json"
mkdir -p "$tmp/o"
printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "%s"}]}]}}\n' "$ps" >"$o"
wire "$personal" "$o" 2>/dev/null
check "hooks object emptied by us is dropped" jqe 'has("hooks") | not' "$o"

# 4. missing file created
n="$tmp/new/settings.json"
wire "$work" "$n" 2>/dev/null
check "missing settings.json created" jqe '.enabledPlugins."agent-harness@nwlnexus" == true' "$n"

# 5. broken file and bad spec: left untouched, exit 0
b="$tmp/b/settings.json"
mkdir -p "$tmp/b"
printf '{not json\n' >"$b"
cp "$b" "$tmp/b.before"
check "broken file: exit 0" wire "$personal" "$b"
check "broken file untouched" cmp -s "$b" "$tmp/b.before"
printf '{"enabledPlugins": []}\n' >"$b"
cp "$b" "$tmp/b.before"
wire "$personal" "$b" 2>/dev/null
check "enabledPlugins not an object: untouched" cmp -s "$b" "$tmp/b.before"
printf '[1]\n' >"$tmp/bad.json"
check "bad spec: exit 0, nothing written" bash -c 'bash -euo pipefail "$1" "$2" "$3" 2>/dev/null && [ ! -e "$3" ]' _ "$script" "$tmp/bad.json" "$tmp/x/settings.json"
check "usage error exits 2" bash -c 'bash -euo pipefail "$1" 2>/dev/null; [ $? -eq 2 ]' _ "$script"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
