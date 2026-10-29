#!/usr/bin/env bash
# Behaviour tests for home/cli/memory/wire.sh (the activation script that merges the memory-gateway hooks
# and MCP entry into Claude Code's own settings.json / .claude.json). Runs on temp copies only.
#   bash tests/memory-wire.sh            (needs bash and jq on PATH; `just test-memory-wire`)
# shellcheck disable=SC2015,SC2016,SC2012  # test helpers quote bash -c bodies on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wire="${MEMORY_WIRE:-$here/../home/cli/memory/wire.sh}"
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
eqjson() { # name, file, jq-expr (must be true)
  jq -e "$3" "$2" >/dev/null 2>&1 && ok "$1" || { bad "$1"; jq -c . "$2" 2>&1 | cut -c1-600; }
}

store=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-memory-hooks
store2=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-memory-hooks

mkspec() { # out store dir mcpfile [extra-target-dir mcpfile]...
  local out="$1" st="$2"
  shift 2
  jq -n --arg st "$st" --args '
    def group($ev; $m; $t; $async): {"hooks": [ ({"type":"command","timeout":$t,
        "command":("MEMORY_GATEWAY_URL=http://memory.example.ts.net MEMORY_SHARE_DIR=" + $st + "/share/memory " + $st + "/bin/" + (if $ev == "SessionStart" then "memory-session-start" else "memory-capture" end))}
        + (if $async then {"async":true} else {} end)) ]} + (if $m == null then {} else {"matcher":$m} end);
    {targets: [ range(0; $ARGS.positional | length; 3) as $i | $ARGS.positional[$i:$i+3] | {
        name: .[0], settings: (.[1] + "/settings.json"), mcp: .[2],
        hooks: {
          "SessionStart": group("SessionStart"; "startup|resume|clear|compact|fork"; 8; false),
          "Stop": group("Stop"; null; 60; true),
          "PreCompact": group("PreCompact"; "manual|auto"; 15; false),
          "SessionEnd": group("SessionEnd"; null; 10; false)},
        mcpServer: {type:"http", url:"http://memory.example.ts.net/mcp",
          headersHelper: ("MEMORY_KEY_FILE=/home/u/.config/memory/gateway-key " + $st + "/bin/memory-mcp-headers")}
      } ]}' "$@" >"$out"
}

# --- realistic pre-existing files -----------------------------------------------------------------------------
acct="$tmp/home/.claude-personal"
mkdir -p "$acct"
cat >"$acct/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status:*)"], "deny": [] },
  "env": { "FOO": "bar" },
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "/usr/local/bin/other-start", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "prettier --write" } ] }
    ],
    "Notification": [ { "hooks": [ { "type": "command", "command": "notify-send claude" } ] } ]
  },
  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
}
JSON
cat >"$acct/.claude.json" <<'JSON'
{
  "numStartups": 42,
  "mcpServers": {
    "gitnexus": { "command": "/home/u/.local/share/mise/shims/gitnexus", "args": ["mcp"] },
    "other": { "type": "http", "url": "https://example.com/mcp" }
  },
  "projects": { "/x": { "mcpServers": { "memory": { "command": "keep-me" } } } }
}
JSON
chmod 600 "$acct/.claude.json"
cp "$acct/settings.json" "$tmp/settings.before.json"
cp "$acct/.claude.json" "$tmp/claude.before.json"
manifest="$tmp/state/wired.json"

# --- 1. fresh install ------------------------------------------------------------------------------------------
mkspec "$tmp/spec1.json" "$store" personal "$acct" "$acct/.claude.json"
check "fresh: apply exits 0" bash "$wire" apply --spec "$tmp/spec1.json" --manifest "$manifest" 2>"$tmp/err"
s="$acct/settings.json"
eqjson "fresh: four events carry exactly one memory hook" "$s" '[.hooks[] | .[] | .hooks[] | select(.command | test("memory-(capture|session-start)"))] | length == 4'
eqjson "fresh: SessionStart keeps the other hook first, ours second" "$s" '.hooks.SessionStart | length == 2 and (.[0].hooks[0].command == "/usr/local/bin/other-start") and (.[1].matcher == "startup|resume|clear|compact|fork") and (.[1].hooks[0].timeout == 8) and (.[1].hooks[0] | has("async") | not)'
eqjson "fresh: Stop is async with 60 s" "$s" '.hooks.Stop[0].hooks[0] | .async == true and .timeout == 60'
eqjson "fresh: PreCompact matcher and timeout" "$s" '.hooks.PreCompact[0] | .matcher == "manual|auto" and .hooks[0].timeout == 15'
eqjson "fresh: SessionEnd timeout" "$s" '.hooks.SessionEnd[0].hooks[0].timeout == 10'
eqjson "fresh: other hooks untouched" "$s" '.hooks.PostToolUse[0].hooks[0].command == "prettier --write" and .hooks.Notification[0].hooks[0].command == "notify-send claude"'
eqjson "fresh: other top-level keys untouched" "$s" '.model == "opus" and .env.FOO == "bar" and .permissions.allow == ["Bash(git status:*)"] and .statusLine.type == "command"'
m="$acct/.claude.json"
eqjson "fresh: mcp entry added" "$m" '.mcpServers.memory | .type == "http" and .url == "http://memory.example.ts.net/mcp" and (.headersHelper | contains("memory-mcp-headers"))'
eqjson "fresh: other mcp servers and keys untouched" "$m" '.numStartups == 42 and .mcpServers.gitnexus.args == ["mcp"] and .mcpServers.other.url == "https://example.com/mcp" and .projects["/x"].mcpServers.memory.command == "keep-me"'
check "fresh: .claude.json mode stays 0600" test "$(stat -c %a "$m" 2>/dev/null || stat -f %Lp "$m")" = 600
eqjson "fresh: manifest records the target" "$manifest" '.targets == [{"settings": "'"$s"'", "mcp": "'"$m"'"}]'

# --- 2. re-run is a no-op ---------------------------------------------------------------------------------------
sum1="$(cksum "$s" "$m" "$manifest")"
inode1="$(ls -i "$s" "$m")"
sleep 1
bash "$wire" apply --spec "$tmp/spec1.json" --manifest "$manifest" 2>"$tmp/err"
check "rerun: files byte-identical" test "$sum1" = "$(cksum "$s" "$m" "$manifest")"
check "rerun: files not rewritten (same inodes)" test "$inode1" = "$(ls -i "$s" "$m")"
check "rerun: nothing logged as updated" bash -c '! grep -q updated "$1"' _ "$tmp/err"

# --- 3. update (new store path, changed timeout) ------------------------------------------------------------------
mkspec "$tmp/spec2.json" "$store2" personal "$acct" "$acct/.claude.json"
jq '.targets[0].hooks.SessionEnd.hooks[0].timeout = 12' "$tmp/spec2.json" >"$tmp/spec2b.json"
bash "$wire" apply --spec "$tmp/spec2b.json" --manifest "$manifest" 2>"$tmp/err"
eqjson "update: all commands now use the new store path" "$s" '[.hooks[][] | .hooks[] | select(.command | test("memory-")) | .command | contains("bbbbbbbb")] | length == 4 and all'
eqjson "update: none of the old store path left" "$s" '[.. | strings | select(contains("aaaaaaaa"))] | length == 0'
eqjson "update: changed timeout applied, still four hooks" "$s" '.hooks.SessionEnd[0].hooks[0].timeout == 12 and ([.hooks[][] | .hooks[] | select(.command | test("memory-(capture|session-start)"))] | length == 4)'
eqjson "update: position preserved (other hook still first)" "$s" '.hooks.SessionStart[0].hooks[0].command == "/usr/local/bin/other-start" and (.hooks.SessionStart | length) == 2'
eqjson "update: mcp helper path updated" "$m" '.mcpServers.memory.headersHelper | contains("bbbbbbbb")'
# a hook someone appended after ours must not make ours hop to the end (and rewrite the file) on the next run
jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"after-ours"}]}]' "$s" >"$tmp/x" && mv "$tmp/x" "$s"
sum2="$(cksum "$s")"
bash "$wire" apply --spec "$tmp/spec2b.json" --manifest "$manifest" 2>"$tmp/err"
check "update: group order stable when a later hook exists" test "$sum2" = "$(cksum "$s")"

# a stale hand-installed copy elsewhere in the file is replaced, not doubled
jq '.hooks.Stop = [{"hooks":[{"type":"command","command":"/opt/old/packages/memory-hooks/bin/memory-capture"}]}] + .hooks.Stop' "$s" >"$tmp/x" && mv "$tmp/x" "$s"
bash "$wire" apply --spec "$tmp/spec2b.json" --manifest "$manifest" 2>"$tmp/err"
eqjson "update: stale hand-installed memory-capture replaced in place" "$s" '[.hooks.Stop[].hooks[].command] == ["MEMORY_GATEWAY_URL=http://memory.example.ts.net MEMORY_SHARE_DIR='"$store2"'/share/memory '"$store2"'/bin/memory-capture", "after-ours"]'

# an event we no longer manage that still carries a memory hook (older module version) is cleaned on apply
jq '.hooks.UserPromptSubmit = [{"hooks":[{"type":"command","command":"/old/memory-hooks/bin/memory-capture"}]},{"hooks":[{"type":"command","command":"keep-prompt-hook"}]}]' "$s" >"$tmp/x" && mv "$tmp/x" "$s"
bash "$wire" apply --spec "$tmp/spec2b.json" --manifest "$manifest" 2>"$tmp/err"
eqjson "update: stale memory hook in an unmanaged event removed, neighbour kept" "$s" '.hooks.UserPromptSubmit == [{"hooks":[{"type":"command","command":"keep-prompt-hook"}]}]'
jq 'del(.hooks.UserPromptSubmit)' "$s" >"$tmp/x" && mv "$tmp/x" "$s"

# --- 4. disable removes only managed entries ----------------------------------------------------------------------
bash "$wire" remove --manifest "$manifest" 2>"$tmp/err"
eqjson "remove: no memory hook left" "$s" '[.. | strings | select(test("memory-(capture|session-start|mcp-guard)"))] | length == 0'
eqjson "remove: events we created are gone, others stay" "$s" '(.hooks | keys | sort) == ["Notification","PostToolUse","SessionStart","Stop"]'
eqjson "remove: someone else's hooks survive (incl. one appended after ours)" "$s" '.hooks.SessionStart == [{"matcher":"startup","hooks":[{"type":"command","command":"/usr/local/bin/other-start","timeout":5}]}] and .hooks.Stop == [{"hooks":[{"type":"command","command":"after-ours"}]}]'
eqjson "remove: mcp entry gone, others and project-scoped memory untouched" "$m" '(.mcpServers | has("memory") | not) and .mcpServers.gitnexus.args == ["mcp"] and .mcpServers.other.url == "https://example.com/mcp" and .projects["/x"].mcpServers.memory.command == "keep-me" and .numStartups == 42'
check "remove: manifest deleted" test ! -e "$manifest"
bash "$wire" remove --manifest "$manifest" 2>"$tmp/err"
check "remove: a second remove is a no-op without a manifest" test $? -eq 0

# full round trip back to the original (minus the hook we appended in this test)
jq 'del(.hooks.Stop)' "$s" >"$tmp/x" && mv "$tmp/x" "$s"
check "round trip: settings equal the originals once the test's own hook is removed" \
  jq -e --slurpfile o "$tmp/settings.before.json" '. == $o[0]' "$s" >/dev/null
check "round trip: .claude.json equals the original" \
  jq -e --slurpfile o "$tmp/claude.before.json" '. == $o[0]' "$m" >/dev/null

# --- 5. absent files ------------------------------------------------------------------------------------------------
fresh="$tmp/home/.claude-work"
mkspec "$tmp/spec3.json" "$store" work "$fresh" "$fresh/.claude.json"
bash "$wire" apply --spec "$tmp/spec3.json" --manifest "$tmp/state/w2.json" 2>"$tmp/err"
eqjson "absent: settings.json created with the four hooks only" "$fresh/settings.json" '(.hooks | keys | sort) == ["PreCompact","SessionEnd","SessionStart","Stop"] and (keys == ["hooks"])'
eqjson "absent: .claude.json created with only the memory server" "$fresh/.claude.json" '.mcpServers | keys == ["memory"]'
check "absent: new .claude.json is 0600" test "$(stat -c %a "$fresh/.claude.json" 2>/dev/null || stat -f %Lp "$fresh/.claude.json")" = 600
bash "$wire" remove --manifest "$tmp/state/w2.json" 2>"$tmp/err"
eqjson "absent: remove leaves valid empty objects behind" "$fresh/settings.json" '. == {}'
eqjson "absent: remove empties mcpServers away" "$fresh/.claude.json" '. == {}'
bash "$wire" remove --manifest "$tmp/state/none.json" 2>"$tmp/err"
check "absent: remove with no manifest and no files exits 0" test $? -eq 0
check "absent: remove did not create files" test ! -e "$tmp/state/none.json"

# --- 6. account dropped from the spec is cleaned; default ~/.claude keeps its mcp file next to the dir ----------------
home2="$tmp/home2"
mkdir -p "$home2/.claude" "$home2/.claude-a"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keepme"}]}]}}' >"$home2/.claude/settings.json"
echo '{"theme":"dark"}' >"$home2/.claude.json"
mkspec "$tmp/spec4.json" "$store" default "$home2/.claude" "$home2/.claude.json" a "$home2/.claude-a" "$home2/.claude-a/.claude.json"
bash "$wire" apply --spec "$tmp/spec4.json" --manifest "$tmp/state/w3.json" 2>"$tmp/err"
eqjson "two accounts: default wired at ~/.claude.json" "$home2/.claude.json" '.theme == "dark" and (.mcpServers.memory.url | endswith("/mcp"))'
eqjson "two accounts: default settings keep foreign Stop hook first" "$home2/.claude/settings.json" '.hooks.Stop[0].hooks[0].command == "keepme" and (.hooks.Stop | length) == 2'
jq '.targets |= map(select(.name == "default"))' "$tmp/spec4.json" >"$tmp/spec5.json"
bash "$wire" apply --spec "$tmp/spec5.json" --manifest "$tmp/state/w3.json" 2>"$tmp/err"
eqjson "two accounts: dropping account a removes its entries" "$home2/.claude-a/settings.json" '. == {}'
eqjson "two accounts: dropped account's mcp entry removed" "$home2/.claude-a/.claude.json" '. == {}'
eqjson "two accounts: the remaining account is still wired" "$home2/.claude/settings.json" '[.hooks[][] | .hooks[] | select(.command | test("memory-"))] | length == 4'

# --- 7. hostile and broken inputs ---------------------------------------------------------------------------------------
bad_dir="$tmp/home3/.claude-x"
mkdir -p "$bad_dir"
printf '{ not json' >"$bad_dir/settings.json"
echo '{"mcpServers":{"memory":{"type":"http","url":"https://elsewhere/mcp"}}}' >"$bad_dir/.claude.json"
mkspec "$tmp/spec6.json" "$store" x "$bad_dir" "$bad_dir/.claude.json"
bash "$wire" apply --spec "$tmp/spec6.json" --manifest "$tmp/state/w4.json" 2>"$tmp/err"
check "broken: apply still exits 0" test $? -eq 0
check "broken: unparsable settings.json left byte-for-byte" test "$(cat "$bad_dir/settings.json")" = '{ not json'
check "broken: a foreign mcpServers.memory is not overwritten and is reported" bash -c 'grep -q "not ours" "$1" && jq -e ".mcpServers.memory.url == \"https://elsewhere/mcp\"" "$2" >/dev/null' _ "$tmp/err" "$bad_dir/.claude.json"
bash "$wire" remove --manifest "$tmp/state/w4.json" 2>"$tmp/err"
check "broken: remove does not delete a foreign memory server either" jq -e '.mcpServers.memory.url == "https://elsewhere/mcp"' "$bad_dir/.claude.json" >/dev/null
bash "$wire" bogus 2>/dev/null
check "bad usage exits 2" test $? -eq 2

# --- 8. route table (olympus-sdk #675): the PreToolUse guard is ours too ----------------------------------------------
home4="$tmp/home4/.claude"
mkdir -p "$home4"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"their-guard"}]}]}}' >"$home4/settings.json"
mkspec "$tmp/spec7.json" "$store" default "$home4" "$tmp/home4/.claude.json"
jq --arg st "$store" '.targets[0].hooks.PreToolUse = {"matcher":"mcp__memory__.*","hooks":[{"type":"command","timeout":10,
  "command":("MEMORY_ROUTES_FILE=/nix/store/x-memory-routes.json " + $st + "/bin/memory-mcp-guard")}]}' "$tmp/spec7.json" >"$tmp/spec7g.json"
bash "$wire" apply --spec "$tmp/spec7g.json" --manifest "$tmp/state/w5.json" 2>"$tmp/err"
eqjson "routes: guard added after the foreign PreToolUse hook" "$home4/settings.json" '.hooks.PreToolUse | length == 2 and .[0].hooks[0].command == "their-guard" and .[1].matcher == "mcp__memory__.*" and (.[1].hooks[0].command | endswith("/bin/memory-mcp-guard"))'
bash "$wire" apply --spec "$tmp/spec7g.json" --manifest "$tmp/state/w5.json" 2>"$tmp/err"
eqjson "routes: re-apply does not double the guard" "$home4/settings.json" '[.hooks.PreToolUse[].hooks[] | select(.command | test("memory-mcp-guard"))] | length == 1'
bash "$wire" apply --spec "$tmp/spec7.json" --manifest "$tmp/state/w5.json" 2>"$tmp/err"
eqjson "routes: a spec without a table (routes = null) removes the guard, keeps theirs" "$home4/settings.json" '.hooks.PreToolUse == [{"matcher":"Bash","hooks":[{"type":"command","command":"their-guard"}]}]'
bash "$wire" apply --spec "$tmp/spec7g.json" --manifest "$tmp/state/w5.json" 2>"$tmp/err"
bash "$wire" remove --manifest "$tmp/state/w5.json" 2>"$tmp/err"
eqjson "routes: remove takes the guard out with the other hooks" "$home4/settings.json" '([.. | strings | select(test("memory-(capture|session-start|mcp-guard)"))] | length == 0) and (.hooks.PreToolUse | length) == 1'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
