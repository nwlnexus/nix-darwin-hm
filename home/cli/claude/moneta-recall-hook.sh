#!/usr/bin/env bash
# moneta-recall-hook.sh — SessionStart auto-recall from moneta (fail-open).
# moneta is the sole memory sink AND source (mem0 recall retired). Resolves
# its sibling formatter whether installed as a nix-store symlink or copied
# into ~/.claude/hooks, then prints the SessionStart additionalContext JSON
# (or {"continue":true} on any error).
set -euo pipefail

MONETA_URL="${MONETA_URL:-https://mem.nwlnexus.io}"
MONETA_TOP_K="${MONETA_TOP_K:-5}"

# Bearer token + CF Access Service Auth come from the personal secrets bundle
# (op-secrets → ~/projects/personal/.env), same as the capture path.
PERSONAL_ENV="${PERSONAL_ENV:-$HOME/projects/personal/.env}"
if [ -f "$PERSONAL_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$PERSONAL_ENV"
  set +a
fi

# Breadcrumbs go to stderr: shown in the hook transcript / debug for
# diagnosis, but never added to the model's context (only stdout is).
log() { printf 'moneta-recall: %s\n' "$*" >&2; }

# Silent fail-open: structural problems the session can't act on.
fail_open() { log "fail-open: ${1:-unspecified}"; printf '{"continue":true}\n'; exit 0; }

# Visible fail-open: the endpoint was unreachable (vs. genuinely empty), so
# surface a short note rather than letting the session assume no memories exist.
emit_unavailable() {
  log "unavailable: ${1:-endpoint unreachable}"
  python3 "$formatter" --unavailable "$MONETA_URL" 2>/dev/null || printf '{"continue":true}\n'
  exit 0
}

command -v python3 >/dev/null 2>&1 || fail_open "python3 not on PATH"
command -v curl    >/dev/null 2>&1 || fail_open "curl not on PATH"

# Token resolution mirrors mnemosyne's monetaWriter: env var first, else file.
token="${MONETA_AUTH_TOKEN:-}"
if [ -z "$token" ]; then
  token_file="${MONETA_TOKEN_FILE:-$HOME/.config/moneta/token}"
  [ -f "$token_file" ] && token="$(tr -d '[:space:]' < "$token_file")"
fi
[ -n "$token" ] || fail_open "no moneta token (MONETA_AUTH_TOKEN or token file)"

# Resolve the directory holding the formatter sibling.
src="${BASH_SOURCE[0]}"
hook_dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)" || fail_open "cannot resolve hook dir"
if [ ! -f "$hook_dir/moneta_recall_format.py" ]; then
  resolved="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src" 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    hook_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)" || fail_open "cannot resolve symlink target dir"
  fi
fi
formatter="$hook_dir/moneta_recall_format.py"
[ -f "$formatter" ] || fail_open "formatter not found beside hook"

# Read the hook stdin JSON and extract cwd (fall back to PWD). Read the WHOLE
# payload regardless of a trailing newline: `read` returns nonzero at
# EOF-without-delimiter but still populates the variable.
stdin_data=""
IFS= read -r -t 2 -d '' stdin_data 2>/dev/null || true
cwd="$(printf '%s' "$stdin_data" | python3 -c 'import sys,json
try:
    print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception:
    print("")' 2>/dev/null || true)"
cwd="${cwd:-${PWD:-}}"
[ -n "$cwd" ] || fail_open "no cwd in stdin or PWD"

# Query by PROJECT NAME, not the raw path: moneta is a semantic (vector)
# search, where "nix-darwin-hm" beats "/Users/x/projects/nix-darwin-hm" — and
# the Worker 500s on path-shaped queries (moneta bug, filed separately).
project="$(basename "$cwd")"
[ -n "$project" ] || project="$cwd"

# CF Access Service Auth headers ride along when provisioned (required once
# the edge gate is live; harmless when it is not).
access_args=()
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  access_args=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")
fi

# Endpoint problems (offline, timeout, non-2xx, Access redirect) are surfaced
# via emit_unavailable; a reachable-but-empty result stays silent in the
# formatter. curl does not follow redirects by default, so an Access 302 can
# never masquerade as a result set.
# insight=false skips moneta's LLM prose synthesis (~5s saved); the remaining
# latency is embedding + tag inference + vector search (~2-4s), hence the 8s
# ceiling (the settings.json hook timeout must stay above it).
resp="$(curl -fsS --connect-timeout 2 --max-time 8 --get \
  --data-urlencode "q=$project" --data-urlencode "topK=$MONETA_TOP_K" \
  --data-urlencode "insight=false" \
  -H "authorization: Bearer $token" "${access_args[@]}" \
  "$MONETA_URL/recall" 2>/dev/null)" || emit_unavailable "curl failed against $MONETA_URL"

printf '%s' "$resp" | MONETA_TOP_K="$MONETA_TOP_K" python3 "$formatter" "$cwd" 2>/dev/null || fail_open "formatter errored on response"
