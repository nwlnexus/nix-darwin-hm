# agent-session: start (or re-attach to) an interactive Claude Code session in tmux with Remote Control attached.
# Installed as ~/.local/bin/agent-session by home/cli/claude/agent-session.nix (wrapped by writeShellApplication,
# which prepends AGENT_SESSION_PER_ACCOUNT=1 on agent hosts and 0 on the Macs).
#
#   agent-session <account> <repo> <issue> [extra claude args]   create the session, or attach if it exists
#   agent-session list                                           list tmux sessions
#   agent-session attach <name>                                  attach to a session by name
#
# The session (and its Remote Control / --name) is called <account>-<repo>-<issue>, for example
# personal-olympus-sdk-558, in ~/projects/<account>/<repo>. On agent hosts it runs with
# CLAUDE_CONFIG_DIR=$HOME/.claude-<account>; on the Macs (one ~/.claude) the variable is left alone.
# Design: nwlnexus/olympus-sdk docs/superpowers/specs/2026-10-26-agent-harness-knowledge-and-hosts-design.md (H17b).
#
# Test hooks (environment): AGENT_SESSION_CLAUDE (command to run, default "claude"), AGENT_SESSION_PROJECTS
# (default ~/projects), AGENT_SESSION_DRY_RUN=1 (print the tmux command instead of running it).

per_account="${AGENT_SESSION_PER_ACCOUNT:-0}"
claude_cmd="${AGENT_SESSION_CLAUDE:-claude}"
projects="${AGENT_SESSION_PROJECTS:-$HOME/projects}"

usage() {
  cat >&2 <<'USAGE'
usage: agent-session <account> <repo> <issue> [extra claude args]
       agent-session list
       agent-session attach <name>
account, repo and issue use letters, digits, '-' and '_' only; the session is named <account>-<repo>-<issue>.
USAGE
  exit 2
}

need_tmux() {
  command -v tmux >/dev/null 2>&1 || {
    echo "agent-session: tmux not found on PATH" >&2
    exit 1
  }
}

attach() { # name
  if ! tmux has-session -t "=$1" 2>/dev/null; then
    echo "agent-session: no tmux session named $1 (see: agent-session list)" >&2
    exit 1
  fi
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$1"
  fi
  exec tmux attach-session -t "=$1"
}

valid() { # value
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

[ $# -ge 1 ] || usage

case "$1" in
  list | ls)
    need_tmux
    tmux list-sessions 2>/dev/null || echo "agent-session: no tmux sessions"
    exit 0
    ;;
  attach | a)
    [ $# -eq 2 ] || usage
    need_tmux
    attach "$2"
    ;;
  -h | --help | help) usage ;;
esac

[ $# -ge 3 ] || usage
account="$1" repo="$2" issue="$3"
shift 3
for v in "$account" "$repo" "$issue"; do
  valid "$v" || {
    echo "agent-session: '$v' must use letters, digits, '-' and '_' only" >&2
    exit 2
  }
done

name="$account-$repo-$issue"
dir="$projects/$account/$repo"

# Re-attach before anything else: the session may outlive its checkout.
if [ -z "${AGENT_SESSION_DRY_RUN:-}" ]; then
  need_tmux
  if tmux has-session -t "=$name" 2>/dev/null; then
    echo "agent-session: $name exists; attaching" >&2
    attach "$name"
  fi
fi

[ -d "$dir" ] || {
  echo "agent-session: $dir does not exist" >&2
  exit 1
}

# One shell string for tmux: values were validated above, extra args are quoted with %q.
cmd=""
if [ "$per_account" = 1 ]; then
  cmd="CLAUDE_CONFIG_DIR=$HOME/.claude-$account "
fi
cmd="${cmd}$claude_cmd --remote-control $name --name $name"
for arg in "$@"; do
  cmd="$cmd $(printf '%q' "$arg")"
done

if [ -n "${AGENT_SESSION_DRY_RUN:-}" ]; then
  printf 'tmux new -d -s %s -c %s %s\n' "$name" "$dir" "$cmd"
  exit 0
fi

tmux new -d -s "$name" -c "$dir" "$cmd"
echo "agent-session: started $name in $dir (attach: agent-session attach $name; or open it from claude.ai/code)" >&2
