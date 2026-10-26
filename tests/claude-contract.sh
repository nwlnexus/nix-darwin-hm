#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/contract.sh (the activation script that keeps the agent-skills session
# contract in a marked block of each Claude dir's CLAUDE.md). Runs on temp files only.
#   bash tests/claude-contract.sh            (needs bash, awk, cmp; `just test-claude-contract`)
# shellcheck disable=SC2016  # test helpers quote bash -c bodies on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${CONTRACT_WIRE:-$here/../home/cli/claude/contract.sh}"
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
wire() { bash -euo pipefail "$script" session-contract "$@"; }
count() { grep -c -- "$1" "$2" || true; }
prefix_ok() { # file: starts with the owner text, byte for byte
  head -c "$(wc -c <"$owner")" "$1" >"$tmp/prefix" && cmp -s "$tmp/prefix" "$owner"
}

frag="$tmp/session-contract.md"
cat >"$frag" <<'MD'
---
name: session-contract
description: test fragment
target: global CLAUDE.md
---

## Session contract

- rule one
MD

owner="$tmp/owner.md"
printf '# Global Claude Code Guidelines\n\n## Model selection\n\nDefault to opus.\n' >"$owner"

# 1. existing file: block appended, owner text kept byte for byte
a="$tmp/a/CLAUDE.md"
mkdir -p "$tmp/a"
cp "$owner" "$a"
chmod 0600 "$a"
wire "$frag" "$a" >/dev/null
check "owner text kept as prefix" prefix_ok "$a"
check "one start marker" [ "$(count 'agent-skills:session-contract:start' "$a")" = 1 ]
check "one end marker" [ "$(count 'agent-skills:session-contract:end' "$a")" = 1 ]
check "body present" grep -qx -- '- rule one' "$a"
check "frontmatter stripped" bash -c '! grep -q "^name: session-contract" "$1" && ! grep -qx -- "---" "$1"' _ "$a"
check "file ends with the end marker" [ "$(tail -n 1 "$a")" = "<!-- agent-skills:session-contract:end -->" ]
check "mode kept (0600)" [ "$(stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a")" = 600 ]

# 2. idempotent: second run changes nothing and says nothing
before="$(cksum <"$a")"
out="$(wire "$frag" "$a")"
check "second run is silent" [ -z "$out" ]
check "second run leaves the file unchanged" [ "$(cksum <"$a")" = "$before" ]

# 3. fragment changed: block replaced, not duplicated
sed -i.bak 's/- rule one/- rule two/' "$frag" && rm -f "$frag.bak"
wire "$frag" "$a" >/dev/null
check "new body written" grep -qx -- '- rule two' "$a"
check "old body gone" bash -c '! grep -qx -- "- rule one" "$1"' _ "$a"
check "still one block" [ "$(count 'agent-skills:session-contract:start' "$a")" = 1 ]
check "owner text still kept" prefix_ok "$a"

# 4. owner adds text after the block: kept, block moves back to the end
printf '\n## Added later\n\nkeep me\n' >>"$a"
wire "$frag" "$a" >/dev/null
check "text added after the block kept" grep -qx 'keep me' "$a"
check "block back at the end" [ "$(tail -n 1 "$a")" = "<!-- agent-skills:session-contract:end -->" ]
check "added text now before the block" bash -c '[ "$(grep -n "keep me" "$1" | cut -d: -f1)" -lt "$(grep -n "session-contract:start" "$1" | cut -d: -f1)" ]' _ "$a"

# 5. missing file (and dir): created with the block only
b="$tmp/b/new/CLAUDE.md"
wire "$frag" "$b" >/dev/null
check "missing file created" [ -f "$b" ]
check "created file starts with the start marker" bash -c 'head -n 1 "$1" | grep -q "^<!-- agent-skills:session-contract:start"' _ "$b"

# 6. symlinked CLAUDE.md: left alone
real="$tmp/real.md"
printf 'managed elsewhere\n' >"$real"
mkdir -p "$tmp/c"
ln -s "$real" "$tmp/c/CLAUDE.md"
wire "$frag" "$tmp/c/CLAUDE.md" >/dev/null 2>&1
check "symlink untouched" [ "$(cat "$real")" = "managed elsewhere" ]

# 7. several targets in one call
d1="$tmp/d1/CLAUDE.md"
d2="$tmp/d2/CLAUDE.md"
wire "$frag" "$d1" "$d2" >/dev/null
check "both targets written" bash -c 'grep -q "rule two" "$1" && grep -q "rule two" "$2"' _ "$d1" "$d2"

# 8. a fragment with no body is refused
printf -- '---\nname: x\n---\n\n' >"$tmp/empty.md"
check "empty fragment refused" bash -c '! bash -euo pipefail "$1" x "$2" "$3" 2>/dev/null' _ "$script" "$tmp/empty.md" "$tmp/e/CLAUDE.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
