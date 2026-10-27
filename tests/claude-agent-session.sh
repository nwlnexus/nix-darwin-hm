#!/usr/bin/env bash
# Behaviour tests for home/cli/claude/agent-session.sh (the tmux launcher). Dry-run checks the command it would run;
# the live checks start a real tmux server on a private socket with a harmless stand-in for `claude`.
#   bash tests/claude-agent-session.sh        (needs bash, tmux; `just test-claude-agent-session`)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${AGENT_SESSION:-$here/../home/cli/claude/agent-session.sh}"
tmp="$(mktemp -d)"
# A private tmux server: never touches the owner's sessions.
export TMUX_TMPDIR="$tmp/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # name, command...
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
as() { bash "$script" "$@"; }

export AGENT_SESSION_PROJECTS="$tmp/projects"
mkdir -p "$AGENT_SESSION_PROJECTS/personal/olympus-sdk" "$AGENT_SESSION_PROJECTS/work/app"
home_dir="$HOME"

# 1. dry run, agent host (per-account config dir)
out="$(AGENT_SESSION_DRY_RUN=1 AGENT_SESSION_PER_ACCOUNT=1 as personal olympus-sdk 558)"
check "host: names the session, dir and config dir" [ "$out" = "tmux new -d -s personal-olympus-sdk-558 -c $tmp/projects/personal/olympus-sdk CLAUDE_CONFIG_DIR=$home_dir/.claude-personal claude --remote-control personal-olympus-sdk-558 --name personal-olympus-sdk-558" ]

# 2. dry run, Mac (single ~/.claude): no CLAUDE_CONFIG_DIR
out="$(AGENT_SESSION_DRY_RUN=1 AGENT_SESSION_PER_ACCOUNT=0 as work app 7)"
check "mac: no CLAUDE_CONFIG_DIR" [ "$out" = "tmux new -d -s work-app-7 -c $tmp/projects/work/app claude --remote-control work-app-7 --name work-app-7" ]

# 3. extra claude args are appended and quoted
out="$(AGENT_SESSION_DRY_RUN=1 as work app 7 --model opus --append-system-prompt 'two words; rm -rf x')"
want='--name work-app-7 --model opus --append-system-prompt two\ words\;\ rm\ -rf\ x'
check "extra args quoted" [ "${out#*"$want"}" != "$out" ]

# 4. argument validation
AGENT_SESSION_DRY_RUN=1 as personal 'a;b' 1 >/dev/null 2>&1
check "shell metacharacters in repo: exit 2" [ "$?" = 2 ]
as personal 'x y' 1 >/dev/null 2>&1
check "space in repo: exit 2" [ "$?" = 2 ]
as personal olympus-sdk >/dev/null 2>&1
check "missing issue: exit 2" [ "$?" = 2 ]
AGENT_SESSION_DRY_RUN=1 as personal nope 1 >/dev/null 2>&1
check "missing repo dir: exit 1" [ "$?" = 1 ]

# 5. live: a real tmux session with the right name running a harmless command
fake="$tmp/fake-claude"
cat >"$fake" <<'SH'
#!/bin/sh
echo "fake claude: $*" >"$FAKE_OUT"
sleep 60
SH
chmod +x "$fake"
export FAKE_OUT="$tmp/fake.out"
AGENT_SESSION_CLAUDE="$fake" AGENT_SESSION_PER_ACCOUNT=1 as personal olympus-sdk 558 2>/dev/null
check "live: tmux session exists with that name" tmux has-session -t =personal-olympus-sdk-558
check "live: tmux ls shows it" bash -c 'tmux ls | grep -q "^personal-olympus-sdk-558:"'
check "live: list shows it" bash -c 'bash "$1" list | grep -q "^personal-olympus-sdk-558:"' _ "$script"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FAKE_OUT" ] && break; sleep 0.3; done
check "live: command got the remote-control name" grep -qx -- "fake claude: --remote-control personal-olympus-sdk-558 --name personal-olympus-sdk-558" "$FAKE_OUT"
pane_dir="$(tmux display-message -p -t personal-olympus-sdk-558 '#{pane_current_path}')"
check "live: started in the repo dir ($pane_dir)" [ "$pane_dir" = "$tmp/projects/personal/olympus-sdk" ]

# 6. second run with the same name does not create another session (it would attach; without a tty that fails)
before="$(tmux ls | wc -l | tr -d ' ')"
AGENT_SESSION_CLAUDE="$fake" as personal olympus-sdk 558 </dev/null >/dev/null 2>"$tmp/second.err"
check "existing session: no second session" [ "$(tmux ls | wc -l | tr -d ' ')" = "$before" ]
check "existing session: says it attaches" grep -q 'exists; attaching' "$tmp/second.err"

# 7. attach to a missing name fails cleanly
as attach nothing-here >/dev/null 2>&1
check "attach missing: exit 1" [ "$?" = 1 ]

# 8. cleanup of the live session
tmux kill-session -t =personal-olympus-sdk-558
check "live: session gone after kill" bash -c '! tmux has-session -t =personal-olympus-sdk-558 2>/dev/null'

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
