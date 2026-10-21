#!/usr/bin/env bash
# Behaviour tests for home/cli/memory/fetch-secrets.sh with a fake `op` (no 1Password, no network).
#   bash tests/memory-fetch-secrets.sh        (`just test-memory-wire` runs it too)
# shellcheck disable=SC2015,SC2016,SC2012  # test helpers quote bash -c bodies on purpose
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fetch="${MEMORY_FETCH:-$here/../home/cli/memory/fetch-secrets.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
check() { # name, command...
  local name="$1"
  shift
  if "$@"; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"; else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# fake op: `op [--account A] read --no-newline REF`; records the token it saw (never the value) and the argv.
cat >"$tmp/op" <<'OP'
#!/bin/sh
echo "$*" >>"$FAKE_OP_LOG"
echo "token=${OP_SERVICE_ACCOUNT_TOKEN:-none}" >>"$FAKE_OP_LOG"
for a in "$@"; do ref=$a; done
case "$ref" in
  op://Dev/memory-gateway-keys/host-default) printf 'mgw_secretvalue_default' ;;
  op://Dev/memory-gateway-keys/host-work) printf 'mgw_secretvalue_work' ;;
  op://Dev/memory-gateway-keys/empty) printf '' ;;
  *) echo '[ERROR] "memory-gateway-keys" isn'"'"'t an item in the "Dev" vault' >&2; exit 1 ;;
esac
OP
chmod +x "$tmp/op"
unset OP_SERVICE_ACCOUNT_TOKEN
export FAKE_OP_LOG="$tmp/oplog"
cfg="$tmp/home/.config/memory"
echo "tok-from-file" >"$tmp/1penv"

bash "$fetch" --op "$tmp/op" --account my.1password.com --token-file "$tmp/1penv" -- \
  op://Dev/memory-gateway-keys/host-default "$cfg/gateway-key" \
  op://Dev/memory-gateway-keys/host-work "$cfg/gateway-key-work" >"$tmp/out" 2>"$tmp/err"
check "reads both items, exit 0" test $? -eq 0
check "writes the value without a newline" test "$(cat "$cfg/gateway-key")" = mgw_secretvalue_default
check "key file is 0600" test "$(mode "$cfg/gateway-key")" = 600
check "directory is 0700" test "$(mode "$cfg")" = 700
check "second file written" test "$(cat "$cfg/gateway-key-work")" = mgw_secretvalue_work
check "uses --account" grep -q -- '--account my.1password.com read' "$FAKE_OP_LOG"
check "token comes from the token file" grep -q 'token=tok-from-file' "$FAKE_OP_LOG"
check "no secret value in stdout/stderr" bash -c '! grep -rq mgw_secretvalue "$1" "$2"' _ "$tmp/out" "$tmp/err"
check "no leftover temp files" test "$(ls -A "$cfg" | wc -l)" -eq 2

# missing item: warning, exit 0, nothing created, others still written
rm -f "$cfg/gateway-key-work"
bash "$fetch" --op "$tmp/op" -- \
  op://Dev/memory-gateway-keys/nope "$cfg/missing" \
  op://Dev/memory-gateway-keys/host-work "$cfg/gateway-key-work" >"$tmp/out" 2>"$tmp/err"
check "missing item: exit 0" test $? -eq 0
check "missing item: warning names the reference" grep -q 'warning: could not read op://Dev/memory-gateway-keys/nope' "$tmp/err"
check "missing item: no file created" test ! -e "$cfg/missing"
check "missing item: later items still fetched" test "$(cat "$cfg/gateway-key-work")" = mgw_secretvalue_work
check "missing item: summary line" grep -q '1 memory secret(s) not provisioned' "$tmp/err"

# failure keeps the existing file; empty value counts as failure
bash "$fetch" --op "$tmp/op" -- op://Dev/memory-gateway-keys/empty "$cfg/gateway-key" >"$tmp/out" 2>"$tmp/err"
check "empty value: existing file kept" test "$(cat "$cfg/gateway-key")" = mgw_secretvalue_default
check "empty value: says it kept the file" grep -q 'keeping the existing' "$tmp/err"

# env token wins over the token file
OP_SERVICE_ACCOUNT_TOKEN=tok-env bash "$fetch" --op "$tmp/op" --token-file "$tmp/1penv" -- \
  op://Dev/memory-gateway-keys/host-default "$cfg/gateway-key" >/dev/null 2>&1
check "env token takes precedence" bash -c 'tail -n 1 "$1" | grep -q token=tok-env' _ "$FAKE_OP_LOG"

# op binary missing entirely: still a warning, not a failure
bash "$fetch" --op "$tmp/does-not-exist" -- op://Dev/x/y "$cfg/other" >/dev/null 2>"$tmp/err"
check "op missing: exit 0 with a warning" bash -c '[ $1 -eq 0 ] && grep -q warning "$2"' _ $? "$tmp/err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
