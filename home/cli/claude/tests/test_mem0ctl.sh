#!/usr/bin/env bash
# Shell tests for mem0ctl — isolated temp HOME, jq + bash only.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM0CTL="$SELF/../mem0ctl.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

setup() {
  TMP="$(mktemp -d)"
  export CLAUDE_DIR="$TMP/.claude" CLAUDE_MEM_DIR="$TMP/.claude-mem" CLAUDE_JSON="$TMP/.claude.json"
  mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/plugins/cache/thedotmack/claude-mem/13.8.1" "$CLAUDE_MEM_DIR/chroma"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/existing/other-hook.sh"}]}]},"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true}}' > "$CLAUDE_DIR/settings.json"
  printf '{"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true},"mcpServers":{"claude-mem":{"x":1},"other":{"y":2}}}' > "$CLAUDE_JSON"
  printf '{}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
  : > "$CLAUDE_MEM_DIR/claude-mem.db"
  : > "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627"
}
teardown() { rm -rf "$TMP"; }

# --- disable-claude-mem: full teardown, keep backup ---
setup
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
dis="$(jq '.enabledPlugins["claude-mem@thedotmack"]' "$CLAUDE_DIR/settings.json")"
keep="$(jq '.enabledPlugins["keep@me"]' "$CLAUDE_DIR/settings.json")"
cj_cm="$(jq '.mcpServers | has("claude-mem")' "$CLAUDE_JSON")"
cj_other="$(jq '.mcpServers | has("other")' "$CLAUDE_JSON")"
cache_gone=$([ ! -d "$CLAUDE_DIR/plugins/cache/thedotmack" ] && echo true || echo false)
db_gone=$([ ! -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && echo true || echo false)
backup_kept=$([ -f "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627" ] && echo true || echo false)
{ [ "$dis" = false ] && [ "$keep" = true ] && [ "$cj_cm" = false ] && [ "$cj_other" = true ] \
  && [ "$cache_gone" = true ] && [ "$db_gone" = true ] && [ "$backup_kept" = true ]; } \
  && ok "disable tears down all layers, keeps backup" \
  || no "disable teardown (dis=$dis keep=$keep cm=$cj_cm other=$cj_other cache=$cache_gone db=$db_gone backup=$backup_kept)"
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1 && ok "disable idempotent" || no "disable idempotent (nonzero)"
teardown

# --- guard: no backup => live DB preserved ---
setup
rm -f "$CLAUDE_MEM_DIR"/*.premem0-*
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
[ -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && ok "no-backup guard keeps live DB" || no "no-backup guard keeps live DB"
teardown

# --- disable: layer-3 (installed_plugins) cleanup, keep unrelated ---
setup
printf '{"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true},"plugins":{"claude-mem@thedotmack":[{"version":"1"}],"keep@me":[{"version":"1"}]},"version":1}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
ip_cm="$(jq '.plugins | has("claude-mem@thedotmack")' "$CLAUDE_DIR/plugins/installed_plugins.json")"
ip_keep="$(jq '.plugins | has("keep@me")' "$CLAUDE_DIR/plugins/installed_plugins.json")"
{ [ "$ip_cm" = false ] && [ "$ip_keep" = true ]; } \
  && ok "disable removes claude-mem from installed_plugins, keeps others" \
  || no "installed_plugins cleanup (cm=$ip_cm keep=$ip_keep)"
teardown

# --- disable: anchored walk preserves project-path keys containing the substring ---
setup
printf '{"pluginUsage":{"claude-mem@thedotmack":{"n":1}},"projects":{"/Users/x/projects/claude-mem-notes":{"keep":1}}}' > "$CLAUDE_JSON"
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
pu_gone="$(jq '.pluginUsage | has("claude-mem@thedotmack")' "$CLAUDE_JSON")"
path_kept="$(jq '.projects | has("/Users/x/projects/claude-mem-notes")' "$CLAUDE_JSON")"
{ [ "$pu_gone" = false ] && [ "$path_kept" = true ]; } \
  && ok "anchored walk drops plugin keys but keeps project-path keys" \
  || no "anchored walk anchoring (pu_gone=$pu_gone path_kept=$path_kept)"
teardown

# --- enable: merge SessionStart (drain first, recall last), keep existing, idempotent ---
setup
MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable --no-verify >/dev/null 2>&1
n1="$(jq '.hooks.SessionStart | length' "$CLAUDE_DIR/settings.json")"
keep_existing="$(jq '[.hooks.SessionStart[].hooks[].command] | any(. == "/existing/other-hook.sh")' "$CLAUDE_DIR/settings.json")"
has_recall="$(jq '[.hooks.SessionStart[].hooks[].command] | any(endswith("mem0-recall-hook.sh"))' "$CLAUDE_DIR/settings.json")"
drain_first="$(jq '.hooks.SessionStart[0].hooks[0].command | endswith("mnemosyne-drain.sh")' "$CLAUDE_DIR/settings.json")"
recall_last="$(jq '.hooks.SessionStart[-1].hooks[0].command | endswith("mem0-recall-hook.sh")' "$CLAUDE_DIR/settings.json")"
{ [ "$n1" = 3 ] && [ "$keep_existing" = true ] && [ "$has_recall" = true ] && [ "$drain_first" = true ] && [ "$recall_last" = true ]; } \
  && ok "enable adds drain(first)+recall(last), keeps existing group" \
  || no "enable SessionStart merge (len=$n1 keep=$keep_existing recall=$has_recall drainFirst=$drain_first recallLast=$recall_last)"

# SessionEnd + PreCompact carry the enqueue hook
se="$(jq '[.hooks.SessionEnd[].hooks[].command] | any(endswith("mnemosyne-enqueue.sh"))' "$CLAUDE_DIR/settings.json")"
pc="$(jq '[.hooks.PreCompact[].hooks[].command] | any(endswith("mnemosyne-enqueue.sh"))' "$CLAUDE_DIR/settings.json")"
{ [ "$se" = true ] && [ "$pc" = true ]; } \
  && ok "enable wires enqueue into SessionEnd + PreCompact" || no "enqueue wiring (se=$se pc=$pc)"

MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable --no-verify >/dev/null 2>&1
n2="$(jq '.hooks.SessionStart | length' "$CLAUDE_DIR/settings.json")"
se2="$(jq '.hooks.SessionEnd | length' "$CLAUDE_DIR/settings.json")"
pc2="$(jq '.hooks.PreCompact | length' "$CLAUDE_DIR/settings.json")"
{ [ "$n2" = 3 ] && [ "$se2" = 1 ] && [ "$pc2" = 1 ]; } \
  && ok "enable idempotent (no duplicate groups across events)" || no "enable idempotent (start=$n2 se=$se2 pc=$pc2)"
# connectivity failure without --no-verify still exits 0
MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable >/dev/null 2>&1 && ok "enable warn-only on unreachable" || no "enable warn-only on unreachable (nonzero)"
teardown

# --- mem0-add.sh: failed write spools to outbox (fail-open) ---
setup
MADD="$SELF/../mem0-add.sh"
export MNEMOSYNE_HOME="$TMP/mnem"
MEM0_URL="http://127.0.0.1:1" bash "$MADD" '{"user_id":"mnemosyne","text":"hello"}' >/dev/null 2>&1
spooled="$(ls "$MNEMOSYNE_HOME/outbox" 2>/dev/null | wc -l | tr -d ' ')"
[ "$spooled" = 1 ] && ok "mem0-add.sh spools failed write to outbox" || no "mem0-add.sh outbox spool (n=$spooled)"
bash "$MADD" '' >/dev/null 2>&1 && ok "mem0-add.sh empty payload is a no-op exit 0" || no "mem0-add.sh empty payload (nonzero)"
unset MNEMOSYNE_HOME
teardown

# --- mnemosyne-enqueue.sh: writes a queue entry, fail-open on junk ---
setup
MENQ="$SELF/../mnemosyne-enqueue.sh"
export MNEMOSYNE_HOME="$TMP/mnem2"
echo '{"transcript_path":"/x/s.jsonl","session_id":"abc","cwd":"/repo"}' | bash "$MENQ" >/dev/null 2>&1
qn="$(ls "$MNEMOSYNE_HOME/queue" 2>/dev/null | wc -l | tr -d ' ')"
qok="$(cat "$MNEMOSYNE_HOME/queue/"*.json 2>/dev/null | jq -r '.session' 2>/dev/null)"
{ [ "$qn" = 1 ] && [ "$qok" = abc ]; } && ok "enqueue writes a queue entry" || no "enqueue write (n=$qn session=$qok)"
echo 'not json' | bash "$MENQ" >/dev/null 2>&1 && ok "enqueue fail-open on junk stdin (exit 0, no crash)" || no "enqueue fail-open (nonzero)"
qn2="$(ls "$MNEMOSYNE_HOME/queue" 2>/dev/null | wc -l | tr -d ' ')"
[ "$qn2" = 1 ] && ok "enqueue drops junk input (no extra entry)" || no "enqueue junk added entry (n=$qn2)"
unset MNEMOSYNE_HOME
teardown

# --- mnemosyne-drain.sh: emits continue, removes an outbox entry the endpoint would 404 only on success ---
setup
MDRAIN="$SELF/../mnemosyne-drain.sh"
export MNEMOSYNE_HOME="$TMP/mnem3"
mkdir -p "$MNEMOSYNE_HOME/outbox"
echo '{"user_id":"mnemosyne","text":"queued"}' > "$MNEMOSYNE_HOME/outbox/x.json"
out="$(echo '{"cwd":"/repo"}' | MEM0_URL="http://127.0.0.1:1" bash "$MDRAIN" 2>/dev/null)"
echo "$out" | grep -q '"continue":true' && ok "drain emits continue json" || no "drain continue json (out=$out)"
# endpoint unreachable → entry LEFT in place for next drain (fail-safe)
[ -f "$MNEMOSYNE_HOME/outbox/x.json" ] && ok "drain leaves outbox entry when endpoint unreachable" || no "drain lost outbox entry on failure"
unset MNEMOSYNE_HOME
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
