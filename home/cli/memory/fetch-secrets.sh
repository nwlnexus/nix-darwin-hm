#!/usr/bin/env bash
# memory-fetch-secrets: write the memory-gateway key / Access-token files from 1Password, fail-soft.
#
# op-secrets (the module behind d.apps.onepassword) is fail-fast: one unreadable item aborts the whole
# activation, including every SSH key and .env after it. The 1Password items for the memory gateway
# (`memory-gateway-keys`, `memory-access-tokens`) are created by hand after the module is merged, so a
# missing item must be a warning here, never a failed switch.
#
# Usage: memory-fetch-secrets --op OP [--account ACCOUNT] [--token-file FILE] [--] REF DEST [REF DEST ...]
#   REF   op://vault/item/field
#   DEST  absolute path, written 0600 (directory 0700), atomically; an existing DEST is kept when the read fails
# Auth, first match wins: OP_SERVICE_ACCOUNT_TOKEN in the environment, then --token-file (the same raw
# service-account token files as d.apps.onepassword.tokenFiles), then whatever `op` session exists.
# No secret value is ever printed or put on a command line; failures print the reference and op's first error line.
set -euo pipefail

op=""
account=""
token_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --op) op="${2:?--op needs a path}"; shift 2 ;;
    --account) account="${2:-}"; shift 2 ;;
    --token-file) token_file="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ -n "$op" ] || { echo "memory-fetch-secrets: --op is required" >&2; exit 2; }
[ $(($# % 2)) -eq 0 ] || { echo "memory-fetch-secrets: REF DEST pairs expected" >&2; exit 2; }

warn() { printf 'memory-fetch-secrets: warning: %s\n' "$*" >&2; }
umask 077

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -n "$token_file" ] && [ -s "$token_file" ]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$token_file")"
  export OP_SERVICE_ACCOUNT_TOKEN
fi
op_args=()
[ -z "$account" ] || op_args+=(--account "$account")

missing=0
while [ $# -gt 0 ]; do
  ref="$1"
  dest="$2"
  shift 2
  mkdir -p "$(dirname "$dest")"
  chmod 700 "$(dirname "$dest")" 2>/dev/null || true
  tmp="$(mktemp "$dest.XXXXXX")"
  err="$(mktemp)"
  if "$op" "${op_args[@]}" read --no-newline "$ref" >"$tmp" 2>"$err" && [ -s "$tmp" ]; then
    chmod 600 "$tmp"
    mv "$tmp" "$dest"
    echo "memory-fetch-secrets: wrote $dest"
  else
    rm -f "$tmp"
    missing=$((missing + 1))
    reason="$(head -n 1 "$err" | cut -c1-200)"
    if [ -s "$dest" ]; then
      warn "could not read $ref (${reason:-empty value}); keeping the existing $dest"
    else
      warn "could not read $ref (${reason:-empty value}); $dest does not exist yet, so the memory MCP server stays disconnected and hooks only spool locally until the item exists and you switch again"
    fi
  fi
  rm -f "$err"
done
[ "$missing" -eq 0 ] || warn "$missing memory secret(s) not provisioned (create the 1Password items, then re-run the switch)"
exit 0
