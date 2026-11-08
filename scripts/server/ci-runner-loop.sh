#!/usr/bin/env bash
# Ephemeral just-in-time GitHub Actions runner loop (d.server.ciRunner, olympus-sdk #694, H20). Runs as root from a
# LaunchDaemon. One iteration is one job:
#   1. mint a GitHub App installation token (JWT RS256 signed with openssl);
#   2. resolve the runner group id and ask for a JIT config for a fresh runner name;
#   3. run the runner as the unprivileged runner user, the JIT config only in its environment;
#   4. kill what the job left behind and wipe every place the runner user can persist in (olympus-sdk #394 F1a):
#      its launchd user/gui domains, cron and at jobs, processes, home (with ~/Library), DARWIN_USER_DIR/CACHE/TEMP
#      and its files in the shared tmp directories.
# Before every registration it also loads the pf anchor that keeps the runner user off private and tailnet
# addresses (#394 F4). Both fail closed: if the wipe or the pf check fails, no runner is registered.
# The App key is root-only and never reaches the runner user. Configuration comes from the environment (set by the
# LaunchDaemon): CI_ORG CI_GROUP CI_LABELS CI_APP_ID_FILE CI_INSTALLATION_ID_FILE CI_PRIVATE_KEY_FILE CI_USER
# CI_WORK_DIR CI_RUNNER_DIR CI_NICE CI_PF_ANCHOR CI_PF_RULES (empty: isolation off) CI_LOG_FILE CI_STATE_FILE (empty: no
# state). The state file (root-only key=value lines: last_wipe_ok, last_wipe_timestamp, last_registration_timestamp)
# is read by the health heartbeat (scripts/server/ci-runner-heartbeat.sh, olympus-sdk #392); it never holds a secret.
set -euo pipefail
umask 077

: "${CI_ORG:?}" "${CI_GROUP:?}" "${CI_LABELS:?}" "${CI_APP_ID_FILE:?}" "${CI_INSTALLATION_ID_FILE:?}"
: "${CI_PRIVATE_KEY_FILE:?}" "${CI_USER:?}" "${CI_WORK_DIR:?}" "${CI_RUNNER_DIR:?}" "${CI_NICE:=10}"
: "${CI_PF_ANCHOR:=com.apple/400.olympus-ci-runner}" "${CI_PF_RULES:=}" "${CI_LOG_FILE:=}" "${CI_STATE_FILE:=}"

backoff_start=30
backoff_cap=300
job_path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
child=""

log() { printf '%s ci-runner: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# state_set KEY VALUE [KEY VALUE ...]: record health facts in the state file (replaced atomically). Never fails the
# loop: the runner works without it, only the heartbeat goes blind.
state_set() {
  [ -n "$CI_STATE_FILE" ] || return 0
  local tmp="$CI_STATE_FILE.tmp" keys="" k
  for ((k = 1; k <= $#; k += 2)); do keys="$keys${keys:+|}${!k}"; done
  {
    install -d -m 0700 -o root -g wheel "$(dirname "$CI_STATE_FILE")" &&
      {
        if [ -f "$CI_STATE_FILE" ]; then grep -Ev "^($keys)=" "$CI_STATE_FILE" || true; fi
        while [ $# -ge 2 ]; do
          printf '%s=%s\n' "$1" "$2"
          shift 2
        done
      } >"$tmp" && mv -f "$tmp" "$CI_STATE_FILE"
  } 2>/dev/null || log "state: could not write $CI_STATE_FILE"
}

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

# Paths under the runner user's home and DARWIN_USER_* dirs that macOS keeps out of root's reach (TCC: app containers
# owned by containermanagerd). Root in this daemon cannot remove them, and neither can the job's own (unsandboxed)
# processes write into them, so they are the only leftovers a wipe accepts (mmini-01 stopped on them before).
tcc_protected() {
  case "$1" in
  *"/Library/Containers" | *"/Library/Containers/"* | *"/Library/Group Containers" | *"/Library/Group Containers/"*) return 0 ;;
  *"/Library/Daemon Containers" | *"/Library/Daemon Containers/"* | *containermanagerd*) return 0 ;;
  # containermanagerd's own bookkeeping (boot.txt, mcm_migration_status.plist); root gets EPERM on it (mmini-01).
  *"/Library/ContainerManager" | *"/Library/ContainerManager/"*) return 0 ;;
  esac
  return 1
}

# has_sunlnk PATH: macOS marks some system-created folders "system no unlink" (sunlnk); root cannot remove them and
# a job cannot set the flag.
has_sunlnk() {
  case ",$(/usr/bin/stat -f %Sf "$1" 2>/dev/null)," in *,sunlnk,*) return 0 ;; esac
  return 1
}

# no_files DIR: DIR holds directories only (nothing a job could leave behind).
no_files() {
  [ -z "$(find "$1" -mindepth 1 ! -type d -print -quit 2>/dev/null)" ]
}

# leftover_ok PATH: a path the wipe may leave: a TCC-protected container path; a file-free folder macOS recreates or
# pins (cfprefsd's ~/Library/Preferences, T/TemporaryItems on data-hub, sunlnk folders such as T/com.apple.trustd,
# seen on the minis); or a
# folder whose every entry is one of those.
leftover_ok() {
  local p=$1 c n=0
  tcc_protected "$p" && return 0
  [ -d "$p" ] && [ ! -L "$p" ] || return 1
  case "$p" in */Library/Preferences | */T/TemporaryItems) no_files "$p" && return 0 ;; esac
  has_sunlnk "$p" && no_files "$p" && return 0
  while IFS= read -r -d '' c; do
    n=$((n + 1))
    leftover_ok "$c" || return 1
  done < <(find "$p" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [ "$n" -gt 0 ]
}

# empty_dir DIR: remove everything inside DIR; fail if anything is left that leftover_ok does not accept.
empty_dir() {
  local dir=$1 p
  local -a left=()
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r -d '' p; do
    leftover_ok "$p" || left+=("$p")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if [ "${#left[@]}" -gt 0 ]; then
    log "wipe: could not remove: ${left[*]}"
    return 1
  fi
}

# Every launchd service label the runner user's domains may hold after a bootout: Apple's own agents and the ones
# installed system-wide in /Library/LaunchAgents (root-owned). Anything else was loaded by a job.
foreign_launchd_services() {
  local uid=$1 domain allowed label
  allowed=$(for f in /Library/LaunchAgents/*.plist; do
    [ -f "$f" ] && /usr/libexec/PlistBuddy -c 'Print :Label' "$f" 2>/dev/null
  done)
  for domain in "user/$uid" "gui/$uid"; do
    launchctl print "$domain" 2>/dev/null |
      awk '/^\tservices = \{/{s=1; next} s && /^\t\}/{s=0} s {print $NF}' |
      while IFS= read -r label; do
        case "$label" in com.apple.*) continue ;; esac
        printf '%s\n' "$allowed" | grep -qxF "$label" && continue
        printf '%s %s\n' "$domain" "$label"
      done
  done
}

# lan6_prefixes: the /56 around each global unicast IPv6 address of the host, one per line; ::/0 when an address
# has a compressed first half (cannot be cut safely without a full parser), so the caller blocks all IPv6 instead.
lan6_prefixes() {
  ifconfig 2>/dev/null | awk '$1 == "inet6" {print $2}' | sed 's/%.*//' | grep -Ei '^[23][0-9a-f]{0,3}:' |
    while IFS=: read -r a b c d _; do
      if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -z "$d" ]; then
        echo "::/0"
      else
        printf '%s:%s:%s:%02x00::/56\n' "$a" "$b" "$c" "$(((0x$d >> 8) & 0xff))"
      fi
    done | sort -u
}

# Kill whatever the runner user left running, remove every persistence path it has and wipe its home (with ~/Library),
# its DARWIN_USER_* dirs, its runner copy and its files in the shared tmp directories, then recreate the home clean.
# Returns non-zero when anything could not be cleaned; the caller then registers no runner.
wipe() {
  local uid group home v d foreign rc=0
  if ! uid=$(id -u "$CI_USER") || ! group=$(id -gn "$CI_USER"); then
    log "wipe: no user $CI_USER"
    return 1
  fi
  home="$CI_WORK_DIR/home"
  # launchd first: a job can bootstrap or `launchctl submit` a KeepAlive agent into its own user domain, which would
  # restart whatever pkill kills and outlive the wipe. A gui domain only exists after a GUI login (never on a server).
  launchctl bootout "gui/$uid" >/dev/null 2>&1 || true
  launchctl bootout "user/$uid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pkill -KILL -U "$uid" 2>/dev/null || true
    pgrep -U "$uid" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -U "$uid" >/dev/null 2>&1; then
    log "wipe: processes of $CI_USER survived: $(pgrep -U "$uid" | tr '\n' ' ')"
    rc=1
  fi
  # cron and at: denied for the user by cron.deny/at.deny (managed by nix); remove anything queued anyway.
  crontab -u "$CI_USER" -r >/dev/null 2>&1 || true
  rm -f "/usr/lib/cron/tabs/$CI_USER"
  find /usr/lib/cron/jobs/ -mindepth 1 -maxdepth 1 -user "$uid" -exec rm -f {} + 2>/dev/null || true
  if [ -e "/usr/lib/cron/tabs/$CI_USER" ] || [ -n "$(find /usr/lib/cron/jobs/ -mindepth 1 -maxdepth 1 -user "$uid" -print -quit 2>/dev/null)" ]; then
    log "wipe: cron or at jobs of $CI_USER remain"
    rc=1
  fi
  for d in cron.deny at.deny; do
    if ! grep -qxF "$CI_USER" "/usr/lib/cron/$d" 2>/dev/null; then
      log "wipe: $CI_USER is not in /usr/lib/cron/$d (darwin-rebuild switch manages it)"
      rc=1
    fi
  done
  # The per-user temporary and cache dirs under /var/folders (DARWIN_USER_DIR, _CACHE_DIR, _TEMP_DIR). Asked of the
  # user itself (the path derives from its uuid); getconf exits at once.
  for v in DARWIN_USER_DIR DARWIN_USER_CACHE_DIR DARWIN_USER_TEMP_DIR; do
    d=$(sudo -u "$CI_USER" /usr/bin/getconf "$v" 2>/dev/null || true)
    d=${d%/}
    case "$d" in
    /var/folders/?*/?*/?*) empty_dir "$d" || rc=1 ;;
    *)
      log "wipe: unexpected $v '$d' for $CI_USER"
      rc=1
      ;;
    esac
  done
  # Anything still loaded into the user's launchd domains that is not Apple's or system-wide.
  foreign=$(foreign_launchd_services "$uid")
  if [ -n "$foreign" ]; then
    log "wipe: launchd services of $CI_USER survived the bootout: $(printf '%s' "$foreign" | tr '\n' ' ')"
    rc=1
  fi
  # macOS refuses to remove a directory that is a user's registered home, even as root and even when empty, so
  # empty the home rather than deleting it. ~/Library goes too (LaunchAgents, Preferences, Keychains, caches);
  # only its TCC-protected container folders may stay (see tcc_protected).
  rm -rf "${CI_WORK_DIR:?}/runner"
  if [ -e "$CI_WORK_DIR/runner" ]; then
    log "wipe: could not remove $CI_WORK_DIR/runner"
    rc=1
  fi
  empty_dir "$home" || rc=1
  find /private/tmp /private/var/tmp /Users/Shared -xdev -maxdepth 1 -user "$uid" -exec rm -rf {} + 2>/dev/null || true
  if [ -n "$(find /private/tmp /private/var/tmp /Users/Shared -xdev -maxdepth 1 -user "$uid" -print -quit 2>/dev/null)" ]; then
    log "wipe: files of $CI_USER remain in the shared tmp directories"
    rc=1
  fi
  install -d -m 0755 -o root -g wheel "$CI_WORK_DIR"
  install -d -m 0700 -o "$CI_USER" -g "$group" "$home" "$home/tmp"
  return "$rc"
}

# Loads the pf anchor that blocks the runner user from private, link-local, loopback (below the ephemeral ports) and
# tailnet addresses and enables pf, then proves it is in force. Apple's main ruleset and com.apple anchors stay as
# they are: the rules live in a child of the com.apple anchor, which /etc/pf.conf already evaluates. With isolation
# off (CI_PF_RULES empty) the anchor is flushed instead.
ensure_pf() {
  local uid ns
  if [ -z "$CI_PF_RULES" ]; then
    pfctl -q -a "$CI_PF_ANCHOR" -F rules >/dev/null 2>&1 || true
    return 0
  fi
  uid=$(id -u "$CI_USER")
  # Something flushed the main ruleset: put Apple's back (it carries the com.apple anchor point).
  if ! pfctl -sr 2>/dev/null | grep -qF 'anchor "com.apple/*"'; then
    log "pf: main ruleset lacks the com.apple anchor point; reloading /etc/pf.conf"
    pfctl -q -f /etc/pf.conf >/dev/null 2>&1 || {
      log "pf: could not load /etc/pf.conf"
      return 1
    }
  fi
  pfctl -q -a "$CI_PF_ANCHOR" -f "$CI_PF_RULES" >/dev/null 2>&1 || {
    log "pf: could not load $CI_PF_RULES into $CI_PF_ANCHOR"
    return 1
  }
  # The site's own global IPv6 prefixes: the /56 around every global address of the host (the ISP delegates the
  # prefix, so it is read here, every iteration). An address that cannot be parsed blocks all IPv6 (fail closed).
  if pfctl -a "$CI_PF_ANCHOR" -sT 2>/dev/null | grep -qx ci_lan6; then
    pfctl -q -a "$CI_PF_ANCHOR" -t ci_lan6 -T flush >/dev/null 2>&1 || true
    lan6=$(lan6_prefixes)
    if [ -n "$lan6" ]; then
      # shellcheck disable=SC2086 # one prefix per word
      pfctl -q -a "$CI_PF_ANCHOR" -t ci_lan6 -T add $lan6 >/dev/null 2>&1 || {
        log "pf: could not fill <ci_lan6>"
        return 1
      }
    fi
  fi
  # The resolvers DHCP gave the host (tools with their own resolver query them as the runner user). Only IPv4.
  ns=$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf 2>/dev/null || true)
  if [ -n "$ns" ]; then
    # shellcheck disable=SC2086 # one address per word
    pfctl -q -a "$CI_PF_ANCHOR" -t ci_dns -T add $ns >/dev/null 2>&1 || log "pf: could not add the resolvers to <ci_dns>"
  fi
  if ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    # -E takes an enable reference (pf stays on for everyone that relies on it), unlike -e.
    pfctl -E >/dev/null 2>&1 || true
  fi
  if ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    log "pf: could not enable pf"
    return 1
  fi
  if ! pfctl -a "$CI_PF_ANCHOR" -sr 2>/dev/null | grep -q "user = $uid"; then
    log "pf: anchor $CI_PF_ANCHOR holds no rules for $CI_USER"
    return 1
  fi
}

# Back off before the next attempt (doubling, capped).
backoff() {
  log "$1; retrying in ${delay}s"
  sleep "$delay"
  delay=$((delay * 2 > backoff_cap ? backoff_cap : delay * 2))
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
  wipe || true
  exit 0
}
trap on_term TERM INT

delay=$backoff_start
while :; do
  # launchd creates the log 0644 if it is missing; it holds job output and runner names.
  if [ -n "$CI_LOG_FILE" ] && [ -f "$CI_LOG_FILE" ]; then
    chown root:wheel "$CI_LOG_FILE" || true
    chmod 0600 "$CI_LOG_FILE" || true
  fi
  if ! { check_secret "$CI_APP_ID_FILE" && check_secret "$CI_INSTALLATION_ID_FILE" && check_secret "$CI_PRIVATE_KEY_FILE"; }; then
    backoff "waiting for the credential files"
    continue
  fi
  # Fail closed: a runner is only registered on a clean user and with the network isolation in force.
  if ! wipe; then
    state_set last_wipe_ok 0 last_wipe_timestamp "$(date +%s)"
    backoff "wipe incomplete, not registering a runner"
    continue
  fi
  state_set last_wipe_ok 1 last_wipe_timestamp "$(date +%s)"
  if ! ensure_pf; then
    backoff "network isolation not in force, not registering a runner"
    continue
  fi
  if ! jit=$(get_jit_config); then
    backoff "could not get a JIT config"
    continue
  fi
  state_set last_registration_timestamp "$(date +%s)"
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
  # The next iteration wipes again before it registers; this pass only clears up right after the job.
  if wipe; then
    state_set last_wipe_ok 1 last_wipe_timestamp "$(date +%s)"
  else
    state_set last_wipe_ok 0 last_wipe_timestamp "$(date +%s)"
    log "wipe after the job incomplete; the next registration waits for a clean wipe"
  fi
  if [ "$status" -ne 0 ] && [ $(($(date +%s) - started)) -lt 20 ]; then
    backoff "runner failed fast"
  else
    delay=$backoff_start
  fi
done
