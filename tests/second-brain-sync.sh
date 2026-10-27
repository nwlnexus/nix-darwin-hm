#!/usr/bin/env bash
# Behaviour tests for home/agent-host/second-brain-sync.sh against local bare repos (no network, no nix).
#   bash tests/second-brain-sync.sh            (needs bash and git; `just test-second-brain-sync`)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SECOND_BRAIN_SYNC:-$here/../home/agent-host/second-brain-sync.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name t
git config --global user.email t@example.invalid
git config --global init.defaultBranch main
git config --global protocol.file.allow always

remote="$tmp/remote.git"
work="$tmp/work"
git init -q --bare "$remote"
git clone -q "$remote" "$work" 2>/dev/null
echo one >"$work/a.md"
git -C "$work" add . && git -C "$work" commit -qm one && git -C "$work" push -q origin main

export SECOND_BRAIN_REPO="$remote"
sync() { bash -euo pipefail "$script" "$@"; }

# clone into a path whose parent does not exist yet
export SECOND_BRAIN_PATH="$tmp/data/brain"
sync clone 2>/dev/null
check "clone creates the checkout" test -f "$SECOND_BRAIN_PATH/a.md"
check "clone leaves no scratch dirs" test -z "$(ls -A "$tmp/data" | grep -v '^brain$' || true)"

# clone is a no-op on an existing checkout, even with local edits
echo local >>"$SECOND_BRAIN_PATH/a.md"
sync clone 2>/dev/null
check "clone keeps local edits" grep -q local "$SECOND_BRAIN_PATH/a.md"
git -C "$SECOND_BRAIN_PATH" checkout -q -- a.md

# clone refuses to touch a non-empty non-git dir
export SECOND_BRAIN_PATH="$tmp/occupied"
mkdir -p "$SECOND_BRAIN_PATH" && echo keep >"$SECOND_BRAIN_PATH/x"
sync clone 2>/dev/null
check "clone leaves a non-git dir alone" test "$(cat "$SECOND_BRAIN_PATH/x")" = keep
check "clone adds nothing to a non-git dir" test "$(ls -A "$SECOND_BRAIN_PATH" | wc -l)" = 1

# a failing clone exits 0 (activation is fail-soft) and leaves nothing behind
export SECOND_BRAIN_PATH="$tmp/nope"
SECOND_BRAIN_REPO="$tmp/missing.git" sync clone 2>/dev/null
check "failed clone exits 0" test $? -eq 0
check "failed clone leaves no checkout" test ! -e "$SECOND_BRAIN_PATH"

# pull fast-forwards
export SECOND_BRAIN_PATH="$tmp/data/brain"
echo two >"$work/b.md"
git -C "$work" add . && git -C "$work" commit -qm two && git -C "$work" push -q origin main
sync pull 2>"$tmp/log"
check "pull fast-forwards" test -f "$SECOND_BRAIN_PATH/b.md"
check "pull logs the move" grep -q 'fast-forwarded' "$tmp/log"
sync pull 2>"$tmp/log"
check "pull logs up to date" grep -q 'up to date' "$tmp/log"

# diverged: pull fails, nothing is reset or merged
echo local >"$SECOND_BRAIN_PATH/c.md"
git -C "$SECOND_BRAIN_PATH" add . && git -C "$SECOND_BRAIN_PATH" commit -qm local
echo three >"$work/d.md"
git -C "$work" add . && git -C "$work" commit -qm three && git -C "$work" push -q origin main
head_before="$(git -C "$SECOND_BRAIN_PATH" rev-parse HEAD)"
sync pull 2>"$tmp/log"
check "diverged pull exits non-zero" test $? -ne 0
check "diverged pull keeps HEAD" test "$(git -C "$SECOND_BRAIN_PATH" rev-parse HEAD)" = "$head_before"
check "diverged pull keeps local commit" test -f "$SECOND_BRAIN_PATH/c.md"
check "diverged pull logs why" grep -q 'nothing was changed' "$tmp/log"

# usage
sync bogus 2>/dev/null
check "unknown mode exits 2" test $? -eq 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
