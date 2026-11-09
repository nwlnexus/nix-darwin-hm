#!/usr/bin/env bash
# Behaviour tests for jev-router (olympus-sdk#647), offline: no Jev, no Anthropic, no real key.
#   bash tests/jev-router.sh        (`just test-jev-router`; needs nix, node is the packaged one, python3, curl, git, jq)
#
# Runs the packaged router (d.agentHost.jevRouter.package) with the generated config (.settings) re-pointed at local
# fakes (tests/lib/jev-fakes.py), then checks:
#   1. jev-route-env: allowlisted origins (scp, https, ssh://, a worktree, a subdir) with the router up print the
#      routed env; a repo off the allowlist, a checkout outside the account tree, a router that is down or hangs
#      print nothing;
#   2. recall canary (Done-when 3): canaries in the system prompt, in SessionStart/recall reminders and in a tool
#      result never reach the fake Jev; the request still reaches the upstream with the client's own login;
#   3. forced timeout (Done-when 4b): a Jev slower than deadlineMs; the request is still served on the default tier
#      and the route log line records the fallback;
#   4. the decision-log shipper: one OTLP record per route line, service.name=jev-router, no canary, rotation
#      followed without duplicates.
# Overrides: JEV_ROUTER_BIN (the jev-router wrapper), JEV_ROUTER_SETTINGS (a config JSON file).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$here/.."
fakes="$here/lib/jev-fakes.py"
route_env="$repo/home/agent-host/jev-route-env.sh"
ship="$repo/home/agent-host/jev-router-ship.py"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  [ -n "${KEEP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # name, command...
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

hm='(builtins.getFlake (toString '"$repo"')).homeConfigurations."nwilliams-lucas@ai-agent-host".config.d.agentHost.jevRouter'
if [ -z "${JEV_ROUTER_BIN:-}" ]; then
  out="$(nix build --no-link --print-out-paths --impure --expr "$hm.package")" || {
    echo "cannot build the jev-router package" >&2
    exit 1
  }
  JEV_ROUTER_BIN="$out/bin/jev-router"
fi
if [ -z "${JEV_ROUTER_SETTINGS:-}" ]; then
  JEV_ROUTER_SETTINGS="$tmp/settings.json"
  nix eval --json --impure --expr "$hm.settings" >"$JEV_ROUTER_SETTINGS" || exit 1
fi

# start <name> <fakes args...>: runs a fake, waits for its port, sets PORT_<name>.
start() {
  local name="$1"
  shift
  python3 -I "$fakes" "$@" --port-file "$tmp/$name.port" &
  pids+=($!)
  for _ in $(seq 50); do [ -s "$tmp/$name.port" ] && break; sleep 0.1; done
  printf -v "PORT_$name" '%s' "$(cat "$tmp/$name.port")"
}
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# router <name> <jev port> <upstream port> [jq filter]: config + process, sets RPORT_<name>.
router() {
  local name="$1" jev="$2" up="$3" extra="${4:-.}" port
  port="$(free_port)"
  jq --argjson port "$port" --arg dir "$tmp/$name" \
    --arg jev "http://127.0.0.1:$jev" --arg up "http://127.0.0.1:$up" '
      .port = $port | .logFile = "\($dir)/router.log" | .stateFile = "\($dir)/sessions.jsonl"
      | .jev.channels[0].baseUrl = $jev
      | .surfaces |= map_values(map_values(.url = $up))' "$JEV_ROUTER_SETTINGS" | jq "$extra" >"$tmp/$name.json"
  mkdir -p "$tmp/$name"
  TYPESAFE_API_KEY=test-key-not-real "$JEV_ROUTER_BIN" serve --config "$tmp/$name.json" >"$tmp/$name.stdout" 2>"$tmp/$name.stderr" &
  pids+=($!)
  for _ in $(seq 100); do curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
  printf -v "RPORT_$name" '%s' "$port"
}

start jev jev --record "$tmp/jev.jsonl"
start up upstream --record "$tmp/up.jsonl"
start otlp otlp --record "$tmp/otlp.jsonl"
start hang hang
router main "$PORT_jev" "$PORT_up"
check "router serves /healthz" curl -fsS "http://127.0.0.1:$RPORT_main/healthz" -o /dev/null

# --- 1. jev-route-env -------------------------------------------------------------------------------------------
root="$tmp/projects/personal"
mkrepo() { # dir origin
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$1" remote add origin "$2"
}
mkrepo "$root/nix-darwin-hm" git@github.com:nwlnexus/nix-darwin-hm.git
mkrepo "$root/agent-plugins" https://github.com/nwlnexus/agent-plugins.git
mkrepo "$root/olympus-infra" ssh://git@github.com/NWLNexus/olympus-infra
mkrepo "$root/olympus-sdk" git@github.com:nwlnexus/olympus-sdk.git
mkrepo "$tmp/elsewhere/nix-darwin-hm" git@github.com:nwlnexus/nix-darwin-hm.git
git -C "$root/nix-darwin-hm" worktree add -q "$root/.worktrees/nixhm-1" -b wt 2>/dev/null
mkdir -p "$root/nix-darwin-hm/home/cli"
renv() { # port dir
  JEV_ROUTE_PORT="$1" JEV_ROUTE_ROOT="$root" \
    JEV_ROUTE_ALLOW="github.com/nwlnexus/agent-plugins github.com/nwlnexus/nix-darwin-hm github.com/nwlnexus/olympus-infra" \
    JEV_ROUTE_EXTRA="CLAUDE_CODE_GATEWAY_HINT_HEADERS=1 ENABLE_TOOL_SEARCH=true" \
    bash -euo pipefail "$route_env" "$2"
}
want="ANTHROPIC_BASE_URL=http://127.0.0.1:$RPORT_main
CLAUDE_CODE_GATEWAY_HINT_HEADERS=1
ENABLE_TOOL_SEARCH=true"
for d in nix-darwin-hm agent-plugins olympus-infra .worktrees/nixhm-1 nix-darwin-hm/home/cli; do
  check "route-env: $d routed" [ "$(renv "$RPORT_main" "$root/$d")" = "$want" ]
done
check "route-env: olympus-sdk (not allowlisted) not routed" [ -z "$(renv "$RPORT_main" "$root/olympus-sdk")" ]
check "route-env: outside the account tree not routed" [ -z "$(renv "$RPORT_main" "$tmp/elsewhere/nix-darwin-hm")" ]
check "route-env: tree root (no repo) not routed" [ -z "$(renv "$RPORT_main" "$root")" ]
check "route-env: router down, not routed" [ -z "$(renv "$(free_port)" "$root/nix-darwin-hm")" ]
t0=$(date +%s%N)
out="$(renv "$PORT_hang" "$root/nix-darwin-hm")"
ms=$((($(date +%s%N) - t0) / 1000000))
check "route-env: router hangs, not routed" [ -z "$out" ]
check "route-env: hang gives up within 1 s (${ms} ms)" [ "$ms" -lt 1000 ]

# --- 2. recall canary --------------------------------------------------------------------------------------------
canary_a="CANARY-647-A$RANDOM$RANDOM"
canary_b="CANARY-647-B$RANDOM$RANDOM"
# send <router port> <session id> <body file>: a Claude Code-shaped request; prints the HTTP status.
send() {
  curl -sS -o "$tmp/resp.json" -w '%{http_code}' "http://127.0.0.1:$1/v1/messages?beta=true" \
    -H 'content-type: application/json' -H 'user-agent: claude-cli/2.1.300 (external, cli)' \
    -H "x-claude-code-session-id: $2" -H 'x-claude-code-request-class: main' \
    -H 'authorization: Bearer test-oauth-token' -H 'anthropic-version: 2023-06-01' \
    -H 'anthropic-beta: oauth-2025-04-20,claude-code-20250219' --data-binary "@$3"
}
jq -n --arg a "$canary_a" --arg b "$canary_b" '{
  model: "claude-opus-5-5", max_tokens: 1024, stream: false,
  system: [{type: "text", text: "You are Claude Code. Project memory: \($a)"}],
  messages: [
    {role: "user", content: [
      {type: "text", text: "<system-reminder>\nSessionStart hook additional context: recalled memory \($a)\n</system-reminder>"},
      {type: "text", text: "Rename the variable tmp to total in utils.py"}]},
    {role: "assistant", content: [
      {type: "text", text: "I will read the file first."},
      {type: "tool_use", id: "toolu_1", name: "Read", input: {file_path: "utils.py"}}]},
    {role: "user", content: [
      {type: "tool_result", tool_use_id: "toolu_1", content: "tmp = 1  # \($b)\nprint(tmp)"}]},
    {role: "assistant", content: [{type: "text", text: "Renamed it in utils.py."}]},
    {role: "user", content: [
      {type: "text", text: "<system-reminder>\nrecall: \($a)\nfile contents: \($b)\n</system-reminder>"},
      {type: "text", text: "Now add a unit test for that function"}]}
  ]}' >"$tmp/canary.json"
check "canary request served (200)" [ "$(send "$RPORT_main" sess-canary "$tmp/canary.json")" = 200 ]
check "Jev was asked (the canary check is not vacuous)" [ -s "$tmp/jev.jsonl" ]
check "Jev payload carries the human request" grep -q 'add a unit test' "$tmp/jev.jsonl"
check "recall/system canary never reaches Jev" bash -c "! grep -q '$canary_a' '$tmp/jev.jsonl'"
check "tool-result canary never reaches Jev" bash -c "! grep -q '$canary_b' '$tmp/jev.jsonl'"
check "the upstream got the full request" grep -q "$canary_a" "$tmp/up.jsonl"
up_last="$(tail -n 1 "$tmp/up.jsonl")"
check "upstream: client's own login passed through" [ "$(jq -r '.headers.authorization // .headers.Authorization' <<<"$up_last")" = "Bearer test-oauth-token" ]
check "upstream: no x-api-key" [ "$(jq -r '[.headers | keys[] | ascii_downcase] | index("x-api-key")' <<<"$up_last")" = null ]
check "upstream: OAuth beta forwarded" bash -c "jq -r '.headers[\"anthropic-beta\"] // .headers[\"Anthropic-Beta\"]' <<<'$up_last' | grep -q oauth-2025-04-20"
check "shadow: model is the account default" [ "$(jq -r .body.model <<<"$up_last")" = claude-opus-5-5 ]
route_main="$(jq -c 'select(.event == "route")' "$tmp/main/router.log" | tail -n 1)"
check "route log: Jev decided (medium)" [ "$(jq -r '[.jev.ok, .tier, .reason] | join(" ")' <<<"$route_main")" = "true medium jev" ]

# --- 3. forced timeout -------------------------------------------------------------------------------------------
start slow jev --record "$tmp/slow.jsonl" --sleep 3
router slowr "$PORT_slow" "$PORT_up" '.jev.deadlineMs = 800 | .jev.channels[0].timeoutMs = 600'
jq '.messages = [.messages[0]]' "$tmp/canary.json" >"$tmp/one.json"
t0=$(date +%s%N)
status="$(send "$RPORT_slowr" sess-timeout "$tmp/one.json")"
ms=$((($(date +%s%N) - t0) / 1000000))
check "timeout: request still served (200)" [ "$status" = 200 ]
check "timeout: served before Jev answers (${ms} ms)" [ "$ms" -lt 2500 ]
check "timeout: Jev was called" [ -s "$tmp/slow.jsonl" ]
route_slow="$(jq -c 'select(.event == "route")' "$tmp/slowr/router.log" | tail -n 1)"
check "timeout: log records the fallback on the default tier" \
  [ "$(jq -r '[.jev.ok, .tier, .reason] | join(" ")' <<<"$route_slow")" = "false medium fallback:default" ]
check "timeout: log names the timeout" bash -c "jq -r .jev.error <<<'$route_slow' | grep -q timeout"

# --- 4. shipper --------------------------------------------------------------------------------------------------
shipit() { # log
  python3 -I "$ship" --once --poll 0.1 --log "$1" --state "$tmp/ship-offset.json" \
    --endpoint "http://127.0.0.1:$PORT_otlp/v1/logs" --resource service.name=jev-router --resource host.name=test
}
log="$tmp/ship.log"
cat "$tmp/main/router.log" "$tmp/slowr/router.log" >"$log"
routes="$(grep -c '"event":"route"' "$log")"
records() { jq -s '[.[].body.resourceLogs[].scopeLogs[].logRecords[]] | length' "$tmp/otlp.jsonl"; }
check "shipper: first run exits 0" shipit "$log"
check "shipper: one record per route line ($routes)" [ "$(records)" = "$routes" ]
check "shipper: service.name=jev-router" \
  [ "$(jq -r '.body.resourceLogs[0].resource.attributes[] | select(.key == "service.name") | .value.stringValue' "$tmp/otlp.jsonl" | sort -u)" = jev-router ]
check "shipper: no canary in OTLP" bash -c "! grep -q -e '$canary_a' -e '$canary_b' '$tmp/otlp.jsonl'"
check "shipper: the timeout is shipped as jev.error_kind=timeout" grep -q '"key": "jev.error_kind", "value": {"stringValue": "timeout"}' "$tmp/otlp.jsonl"
shipit "$log"
check "shipper: a restart ships nothing twice" [ "$(records)" = "$routes" ]
line="$(jq -c 'select(.event == "route")' "$log" | head -n 1)"
echo "$line" >>"$log"
mv "$log" "$log.1"
echo "$line" >"$log"
shipit "$log"
check "shipper: follows rotation (2 new records, no duplicates)" [ "$(records)" = "$((routes + 2))" ]

echo "jev-router: $pass passed, $fail failed"
[ "$fail" = 0 ]
