# memory-watchdog: one-shot sampler + orphaned-AI-tooling reaper, run by
# launchd every 60s (see memory-watchdog.nix).
#
# Why this exists: on 2026-07-13 this host was halted twice by kernel OOM
# (JetsamEvent reports showed 964 orphaned node processes / ~42GB from
# accumulated AI-agent sessions, each spawning ~14 stdio MCP servers that
# never exit when their parent dies). This watchdog (a) leaves a 1-line/min
# breadcrumb log so the next incident is diagnosable without forensics, and
# (b) reaps orphaned AI-tooling processes before they can drown the machine.
#
# Reaping policy — escalation by memory pressure, never a blanket kill:
# legitimate detached work (e.g. mnemosyne background consolidation) is also
# orphaned to PID 1, so orphans only die after sustained presence at normal
# pressure, quickly under warn, and immediately under critical (the
# system-halt scenario this exists to prevent). Strikes accrue once per run
# (~1/min), tracked per pid+start-time so PID reuse cannot kill an innocent.

STATE_DIR="${MEMORY_WATCHDOG_STATE_DIR:-$HOME/.cache/memory-watchdog}"
LOG="$STATE_DIR/watchdog.log"
STRIKES="$STATE_DIR/strikes.state"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Strike thresholds (runs seen as orphan before TERM) per pressure level.
NORMAL_TERM_STRIKES=30 # ~30 min: only true zombies survive this long
WARN_TERM_STRIKES=2    # ~2 min
CRIT_TERM_STRIKES=0    # immediate

# An orphan is reaped only if its command line looks like AI tooling. First
# token must be a JS runtime or the claude CLI; JS runtimes additionally need
# an AI-tooling keyword in their arguments so ordinary detached node work
# (builds, servers) is never touched.
RUNTIME_RE='(^|/)(node|bun|npx|npm)( |$)'
KEYWORD_RE='mcp|context-mode|gitnexus|claude|copilot|cursor|playwright|chrome-devtools'
CLAUDE_RE='(^|/)(claude|cursor-agent)( |$)'

mkdir -p "$STATE_DIR"
touch "$STRIKES"

# --- sample ---------------------------------------------------------------
stamp=$(date '+%Y-%m-%dT%H:%M:%S')
# 1=normal 2=warn 4=critical; override is a test/drill hook only.
pressure=${MEMORY_WATCHDOG_FORCE_PRESSURE:-$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)}
free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2}' || true)
free_pct=${free_pct:-?}

snapshot=$(ps -axo rss=,ucomm=)
node_count=$(printf '%s\n' "$snapshot" | awk '$2=="node"{n++} END{print n+0}')
# The claude CLI execs a version-named binary (ucomm "2.1.207"), so count via
# the full command line instead of the process name (pgrep can't see past the
# exec'd name either, hence the ps pipe).
# shellcheck disable=SC2009
claude_count=$(ps -axo command= | grep -cE '(^|/)(claude|cursor-agent)( |$)' || true)
top3=$(printf '%s\n' "$snapshot" | sort -rn | head -3 | awk '{printf "%s:%dMB ", $2, $1/1024}')

# --- find orphaned AI-tooling processes ------------------------------------
# Managed launchd jobs also have ppid 1; exclude their PIDs so a deliberately
# daemonized tool (or this watchdog's own kin) is never a candidate.
managed_pids=$(launchctl list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ')
me=$(id -un)

candidates=$(ps -axo pid=,ppid=,user=,lstart=,command= | awk \
  -v me="$me" -v managed=" $managed_pids " -v self="$$" \
  -v runtime_re="$RUNTIME_RE" -v keyword_re="$KEYWORD_RE" -v claude_re="$CLAUDE_RE" '
  $2 == 1 && $3 == me && $1 != self && index(managed, " " $1 " ") == 0 {
    pid = $1
    # lstart is fields 4-8 (e.g. "Mon Jul 13 16:51:51 2026")
    key = pid ":" $4 $5 $6 $7 $8
    cmd = ""
    for (i = 9; i <= NF; i++) cmd = cmd (i > 9 ? " " : "") $i
    if ((cmd ~ runtime_re && cmd ~ keyword_re) || cmd ~ claude_re)
      print key "\t" cmd
  }')

# --- strike bookkeeping & reap ---------------------------------------------
case "$pressure" in
4) term_at=$CRIT_TERM_STRIKES ;;
2) term_at=$WARN_TERM_STRIKES ;;
*) term_at=$NORMAL_TERM_STRIKES ;;
esac

killed=""
new_strikes=""
while IFS=$(printf '\t') read -r key cmd; do
  [ -n "$key" ] || continue
  pid=${key%%:*}
  prev=$(awk -F'\t' -v k="$key" '$1==k{print $2}' "$STRIKES")
  strikes=$((${prev:-0} + 1))
  action=""
  if [ "$strikes" -gt "$((term_at + 1))" ]; then
    action="KILL"
  elif [ "$strikes" -gt "$term_at" ]; then
    action="TERM"
  fi
  if [ -n "$action" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "DRY-RUN would $action $pid: $cmd"
    else
      kill "-$action" "$pid" 2>/dev/null || true
      killed="$killed $pid($action)"
      echo "$stamp REAP sig=$action pid=$pid strikes=$strikes pressure=$pressure cmd=${cmd:0:200}" >>"$LOG"
    fi
  fi
  new_strikes="$new_strikes$key	$strikes
"
done <<EOF
$candidates
EOF

# Persist strikes only for orphans still present; everything else ages out.
printf '%s' "$new_strikes" >"$STRIKES"

# --- log -------------------------------------------------------------------
orphan_count=$(printf '%s' "$candidates" | grep -c . || true)
echo "$stamp pressure=$pressure free=${free_pct}% node=$node_count claude=$claude_count ai_orphans=$orphan_count top: $top3" >>"$LOG"

if [ -n "$killed" ] && [ "$DRY_RUN" = 0 ]; then
  osascript -e "display notification \"Reaped orphaned AI processes:$killed\" with title \"memory-watchdog\"" 2>/dev/null || true
fi

# Rotate at ~5MB so the breadcrumb log can never become its own problem.
if [ "$(wc -c <"$LOG")" -gt 5242880 ]; then
  mv "$LOG" "$LOG.1"
fi
