#!/usr/bin/env bash
# A work-only host (d.workOnly) must evaluate without the private `olympus-sdk` input (olympus-sdk #691).
#
# Copies the tracked tree to a temp dir, points the input's lock entry at an unreachable repository with a
# narHash no store path has, and evaluates the host's system derivation from that copy. Nix fetches flake inputs
# lazily, so this only succeeds when nothing in the host's evaluation touches the input. As a control, a host
# that does use it (NWL-MMINI: memory hooks, autoMode, /etc/nix/inputs) must fail the same way.
#
# Needs nix and jq. Usage: bash tests/work-only-private-input.sh [host]
set -euo pipefail

host="${1:-dtlr-ai-agent-host}"
control="NWL-MMINI"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then echo "ok   $d"; else
    echo "FAIL $d"
    fail=1
  fi
}

# Tracked files plus anything staged (a new host file must be `git add`ed for the flake to see it anyway).
(cd "$repo" && git ls-files -z --cached | tar --null -T - -cf -) | tar -xf - -C "$tmp"
[ -f "$tmp/flake.nix" ] || {
  echo "copy failed" >&2
  exit 2
}

jq '.nodes["olympus-sdk"].locked = {
      type: "git",
      url: "ssh://git@invalid.invalid/no-such-repo",
      ref: "main",
      rev: "0000000000000000000000000000000000000000",
      lastModified: 0,
      revCount: 0,
      narHash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }' "$repo/flake.lock" >"$tmp/flake.lock"

eval_host() {
  GIT_SSH_COMMAND=false nix eval --raw --no-write-lock-file \
    "path:$tmp#darwinConfigurations.$1.config.system.build.toplevel.drvPath" >"$tmp/$1.out" 2>"$tmp/$1.err"
}

check "$host evaluates with the private input unreachable" eval_host "$host"
[ "$fail" = 0 ] || sed -n '1,30p' "$tmp/$host.err" >&2
if eval_host "$control"; then
  echo "FAIL control: $control evaluated without the private input, so this test proves nothing"
  fail=1
else
  echo "ok   control: $control does not evaluate without the private input"
fi

exit "$fail"
