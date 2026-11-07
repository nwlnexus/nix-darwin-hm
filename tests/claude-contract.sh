#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/contract.sh (contract-unwire: removes the session-contract block the old nix
# harness kept at the end of each Claude dir's CLAUDE.md; the agent-harness plugin delivers the contract now).
# Runs on temp files only.
#   bash tests/claude-contract.sh            (needs bash, awk, grep, cmp; `just test-claude-contract`)
# shellcheck disable=SC2016  # test helpers quote bash -c bodies on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${CONTRACT_UNWIRE:-$here/../home/cli/claude/contract.sh}"
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
unwire() { bash -euo pipefail "$script" session-contract "$@"; }

owner="$tmp/owner.md"
printf '# Global Claude Code Guidelines\n\n## Model selection\n\nDefault to opus.\n' >"$owner"
block() {
  printf '<!-- agent-skills:session-contract:start (managed by nix-darwin-hm from nwlnexus/agent-skills fragments/session-contract.md; edit it there, changes here are overwritten) -->\n## Session contract\n\n- rule one\n<!-- agent-skills:session-contract:end -->\n'
}

# 1. owner text + block: block and the blank line before it go, owner text kept byte for byte
a="$tmp/a/CLAUDE.md"
mkdir -p "$(dirname "$a")"
{ cat "$owner"; printf '\n'; block; } >"$a"
chmod 0640 "$a"
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
ino=$(inode "$a")
unwire "$a" >/dev/null 2>&1
check "block removed, owner text kept" cmp -s "$a" "$owner"
check "mode kept" bash -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = 640 ]' _ "$a"
check "inode kept" [ "$(inode "$a")" = "$ino" ]

# 2. idempotent: second run writes nothing
cp "$a" "$tmp/a.before"
out=$(unwire "$a" 2>&1)
check "second run is a no-op" bash -c 'cmp -s "$1" "$2" && [ -z "$3" ]' _ "$a" "$tmp/a.before" "$out"

# 3. owner text after the block (hand edit) is kept
b="$tmp/b/CLAUDE.md"
mkdir -p "$(dirname "$b")"
{ cat "$owner"; block; printf '## Later\n'; } >"$b"
unwire "$b" >/dev/null 2>&1
check "text after the block kept" bash -c 'grep -q "^## Later" "$1" && ! grep -q "agent-skills:" "$1" && ! grep -q "rule one" "$1"' _ "$b"

# 4. file with only the block becomes empty
c="$tmp/c/CLAUDE.md"
mkdir -p "$(dirname "$c")"
block >"$c"
unwire "$c" >/dev/null 2>&1
check "block-only file left empty" bash -c '[ ! -s "$1" ]' _ "$c"

# 5. missing file, file without block, symlink: untouched
cp "$owner" "$tmp/plain.md"
ln -s "$a" "$tmp/link.md"
block >>"$a"
cp "$a" "$tmp/a.withblock"
unwire "$tmp/missing/CLAUDE.md" "$tmp/plain.md" "$tmp/link.md" >/dev/null 2>&1
check "missing file not created" bash -c '[ ! -e "$1" ]' _ "$tmp/missing/CLAUDE.md"
check "file without block untouched" cmp -s "$tmp/plain.md" "$owner"
check "symlink target untouched" cmp -s "$a" "$tmp/a.withblock"

# 6. several targets in one call
d1="$tmp/d1/CLAUDE.md" d2="$tmp/d2/CLAUDE.md"
mkdir -p "$(dirname "$d1")" "$(dirname "$d2")"
{ cat "$owner"; block; } >"$d1"
{ cat "$owner"; block; } >"$d2"
unwire "$d1" "$d2" >/dev/null 2>&1
check "both targets cleaned" bash -c 'cmp -s "$1" "$3" && cmp -s "$2" "$3"' _ "$d1" "$d2" "$owner"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
