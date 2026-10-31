#!/usr/bin/env bash
# Ephemeral just-in-time GitHub Actions runner loop (d.server.ciRunner, olympus-sdk #694, H20). Runs as root from a
# LaunchDaemon. One iteration is one job:
#   1. mint a GitHub App installation token (JWT RS256 signed with openssl);
#   2. resolve the runner group id and ask for a JIT config for a fresh runner name;
#   3. run the runner as the unprivileged runner user, the JIT config only in its environment;
#   4. kill what the job left behind and wipe the runner user's home and work dir.
# The App key is root-only and never reaches the runner user. Configuration comes from the environment (set by the
# LaunchDaemon): CI_ORG CI_GROUP CI_LABELS CI_APP_ID_FILE CI_INSTALLATION_ID_FILE CI_PRIVATE_KEY_FILE CI_USER
# CI_WORK_DIR CI_RUNNER_DIR CI_NICE.
set -euo pipefail
umask 077

: "${CI_ORG:?}" "${CI_GROUP:?}" "${CI_LABELS:?}" "${CI_APP_ID_FILE:?}" "${CI_INSTALLATION_ID_FILE:?}"
: "${CI_PRIVATE_KEY_FILE:?}" "${CI_USER:?}" "${CI_WORK_DIR:?}" "${CI_RUNNER_DIR:?}" "${CI_NICE:=10}"

backoff_start=30
backoff_cap=300
job_path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
child=""

log() { printf '%s ci-runner: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# A secret file must be a regular file owned by root and closed to group and others.
check_secret() {
  local f=$1 owner mode
  [ -f "$f" ] || {
    log "missing $f (see docs/hosts/mmini-01.md)"
    return 1
  }
  owner=$(stat -f %Su "$f")
  mode=$(stat -f %Lp "$f")
  if [ "$owner" != root ] || [ "${mode: -2}" != 00 ]; then
    log "$f must be owned by root with mode 0400 (is $owner $mode)"
    return 1
  fi
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_jwt() {
  local now header payload unsigned sig app_id
  app_id=$(tr -d '[:space:]' <"$CI_APP_ID_FILE")
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id")
  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$CI_PRIVATE_KEY_FILE" -binary | b64url)
  printf '%s.%s' "$unsigned" "$sig"
}

# gh_api METHOD PATH BEARER [JSON-BODY]. The bearer goes to curl on stdin (-K -), never on argv, where every local
# user could read it with ps.
gh_api() {
  local method=$1 path=$2 bearer=$3 body=${4-}
  local -a args=(--silent --show-error --fail-with-body --max-time 30 -K - -X "$method"
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$bearer" | curl "${args[@]}" "https://api.github.com$path"
}

# Prints the base64 JIT config for a new runner; all progress goes to stderr.
get_jit_config() {
  local jwt token installation group_id name host body labels resp
  jwt=$(mint_jwt)
  installation=$(tr -d '[:space:]' <"$CI_INSTALLATION_ID_FILE")
  token=$(gh_api POST "/app/installations/$installation/access_tokens" "$jwt" | jq -er .token)
  group_id=$(gh_api GET "/orgs/$CI_ORG/actions/runner-groups?per_page=100" "$token" |
    jq -er --arg g "$CI_GROUP" '.runner_groups[] | select(.name == $g) | .id' | head -n 1)
  host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
  name="$host-$(date +%Y%m%d%H%M%S)"
  labels=$(printf '%s' "$CI_LABELS" | jq -Rc 'split(",")')
  body=$(jq -nc --arg name "$name" --argjson gid "$group_id" --argjson labels "$labels" \
    '{name: $name, runner_group_id: $gid, labels: $labels, work_folder: "_work"}')
  resp=$(gh_api POST "/orgs/$CI_ORG/actions/runners/generate-jitconfig" "$token" "$body")
  log "registered runner $name in group $CI_GROUP" >&2
  printf '%s' "$resp" | jq -er .encoded_jit_config
}

# Kill whatever the runner user left running and wipe its home, its runner copy and its files in the shared tmp
# directories, then recreate the home clean.
wipe() {
  local uid group
  uid=$(id -u "$CI_USER")
  group=$(id -gn "$CI_USER")
  pkill -KILL -U "$uid" 2>/dev/null || true
  # macOS refuses to remove a directory that is a user's registered home, even as root and even when empty, so
  # empty the home rather than deleting it.
  rm -rf "${CI_WORK_DIR:?}/runner"
  # macOS also creates ~/Library for any user that runs processes, and its containermanagerd subfolders are
  # TCC-protected: root in this daemon cannot remove them, and failing here stopped the loop for good (mmini-01).
  # Leave ~/Library to macOS (nothing in it runs without a GUI login, which a server never has) and never let
  # the wipe end the loop.
  if [ -d "$CI_WORK_DIR/home" ]; then
    find "$CI_WORK_DIR/home" -mindepth 1 -maxdepth 1 ! -name Library -exec rm -rf {} + || log "wipe: some files could not be removed"
  fi
  find /private/tmp /private/var/tmp -xdev -maxdepth 1 -user "$CI_USER" -exec rm -rf {} + 2>/dev/null || true
  install -d -m 0755 -o root -g wheel "$CI_WORK_DIR"
  install -d -m 0700 -o "$CI_USER" -g "$group" "$CI_WORK_DIR/home" "$CI_WORK_DIR/home/tmp"
}

# A writable copy of the pinned runner (an APFS clone when the store allows, else a plain copy).
stage_runner() {
  local group
  group=$(id -gn "$CI_USER")
  install -d -m 0755 -o root -g wheel "$CI_WORK_DIR/runner"
  cp -cR "$CI_RUNNER_DIR/." "$CI_WORK_DIR/runner/" 2>/dev/null || cp -R "$CI_RUNNER_DIR/." "$CI_WORK_DIR/runner/"
  chown -R "$CI_USER:$group" "$CI_WORK_DIR/runner"
  chmod -R u+w "$CI_WORK_DIR/runner"
}

on_term() {
  trap - TERM INT
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null || true
  wipe
  exit 0
}
trap on_term TERM INT

delay=$backoff_start
while :; do
  if ! { check_secret "$CI_APP_ID_FILE" && check_secret "$CI_INSTALLATION_ID_FILE" && check_secret "$CI_PRIVATE_KEY_FILE"; }; then
    log "waiting ${delay}s for the credential files"
    sleep "$delay"
    delay=$((delay * 2 > backoff_cap ? backoff_cap : delay * 2))
    continue
  fi
  wipe
  if ! jit=$(get_jit_config); then
    log "could not get a JIT config; retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2 > backoff_cap ? backoff_cap : delay * 2))
    continue
  fi
  stage_runner
  started=$(date +%s)
  # The JIT config travels in the environment only (sudo keeps just the named variables); argv carries no secret.
  ACTIONS_RUNNER_INPUT_JITCONFIG=$jit TMPDIR="$CI_WORK_DIR/home/tmp" PATH=$job_path \
    sudo -u "$CI_USER" -H --preserve-env=ACTIONS_RUNNER_INPUT_JITCONFIG,TMPDIR,PATH \
    /bin/sh -c "cd '$CI_WORK_DIR/runner' && exec nice -n '$CI_NICE' ./run.sh" &
  child=$!
  unset jit
  status=0
  wait "$child" || status=$?
  child=""
  log "runner exited with status $status"
  wipe
  if [ "$status" -ne 0 ] && [ $(($(date +%s) - started)) -lt 20 ]; then
    log "runner failed fast; backing off ${delay}s"
    sleep "$delay"
    delay=$((delay * 2 > backoff_cap ? backoff_cap : delay * 2))
  else
    delay=$backoff_start
  fi
done
