# jev-route-env [dir]: the environment a Claude Code session in <dir> needs to go through jev-router, one KEY=value
# per line, or nothing. Installed by home/agent-host/jev-router.nix (writeShellApplication), which prepends the
# defaults below; olympus-sdk#647.
#
# It prints something only when all of these hold, so every other session keeps its static model:
#   - <dir> is inside the routed account's tree (JEV_ROUTE_ROOT);
#   - `git remote get-url origin` of <dir> (a checkout or a linked worktree) is on the allowlist (JEV_ROUTE_ALLOW,
#     host/owner/repo; https, ssh:// and scp-style git@host:owner/repo forms all match);
#   - the router answers GET /healthz with "ok":true within JEV_ROUTE_TIMEOUT seconds (default 0.3).
#
# Environment: JEV_ROUTE_PORT, JEV_ROUTE_ROOT, JEV_ROUTE_ALLOW (space separated), JEV_ROUTE_EXTRA (space separated
# KEY=value pairs printed after ANTHROPIC_BASE_URL), JEV_ROUTE_TIMEOUT.

port="${JEV_ROUTE_PORT:-4000}"
root="${JEV_ROUTE_ROOT:-}"
allow="${JEV_ROUTE_ALLOW:-}"
extra="${JEV_ROUTE_EXTRA:-}"
wait_s="${JEV_ROUTE_TIMEOUT:-0.3}"

[ -n "$root" ] || exit 0
dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || exit 0
root="$(cd "$root" 2>/dev/null && pwd -P)" || exit 0
case "$dir/" in
  "$root"/*) ;;
  *) exit 0 ;;
esac

url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || exit 0

# Normalize to host/owner/repo in lower case.
u="${url%/}"
u="${u%.git}"
case "$u" in
  *://*)
    u="${u#*://}" # https://, ssh://, git+ssh://
    u="${u#*@}"   # user@
    ;;
  *:*)
    u="${u#*@}" # scp-style [user@]host:owner/repo
    u="${u/://}"
    ;;
  *) exit 0 ;; # a local path
esac
host="${u%%/*}"
path="${u#*/}"
host="${host%%:*}" # ssh://git@github.com:22/owner/repo
u="$(printf '%s/%s' "$host" "$path" | tr '[:upper:]' '[:lower:]')"

matched=0
for a in $allow; do
  if [ "$u" = "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" ]; then
    matched=1
    break
  fi
done
[ "$matched" = 1 ] || exit 0

health="$(curl -fsS --noproxy '*' --max-time "$wait_s" "http://127.0.0.1:$port/healthz" 2>/dev/null)" || exit 0
case "$health" in
  *'"ok":true'*) ;;
  *) exit 0 ;;
esac

printf 'ANTHROPIC_BASE_URL=http://127.0.0.1:%s\n' "$port"
for kv in $extra; do
  printf '%s\n' "$kv"
done
