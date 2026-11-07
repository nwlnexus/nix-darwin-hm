#!/usr/bin/env bash
# Health heartbeat for the native macOS CI runner (d.server.ciRunner.heartbeat, olympus-sdk #392). Run as root by a
# LaunchDaemon every StartInterval seconds; one run pushes one data point per gauge to an OpenTelemetry collector
# over OTLP/HTTP JSON and exits. Gauges (resource attributes service.name=ci-runner and host.name=<LocalHostName>,
# the same host prefix as the runner names):
#   ci_runner_daemon_up                            1 while the runner loop's LaunchDaemon is running, else 0
#   ci_runner_runner_up                            1 while a registered runner (Runner.Listener) of the runner
#                                                  user is running (idle or in a job), else 0
#   ci_runner_last_registration_timestamp_seconds  Unix time of the loop's last successful JIT registration
#   ci_runner_last_wipe_ok                         1 if the loop's last wipe succeeded, 0 if it failed
# The last two come from the loop's state file and are left out until the loop has written them.
# Nothing secret is read or sent. Configuration comes from the environment (set by the LaunchDaemon):
# CI_HB_ENDPOINT (collector base URL; /v1/metrics is appended) CI_HB_LABEL CI_USER CI_STATE_FILE [CI_HB_HOST].
set -euo pipefail
umask 077

: "${CI_HB_ENDPOINT:?}" "${CI_HB_LABEL:?}" "${CI_USER:?}" "${CI_STATE_FILE:=}" "${CI_HB_HOST:=}"

log() { printf '%s ci-runner-heartbeat: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# state_get KEY: the value of KEY=<digits> in the loop's state file, or nothing.
state_get() {
  [ -n "$CI_STATE_FILE" ] && [ -f "$CI_STATE_FILE" ] || return 0
  awk -F= -v k="$1" '$1 == k && $2 ~ /^[0-9]+$/ {v = $2} END {if (v != "") print v}' "$CI_STATE_FILE"
}

host=${CI_HB_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}

daemon_up=0
if launchctl print "system/$CI_HB_LABEL" 2>/dev/null | grep -q "^$(printf '\t')state = running$"; then
  daemon_up=1
fi
runner_up=0
if pgrep -U "$CI_USER" -f Runner.Listener >/dev/null 2>&1; then
  runner_up=1
fi
registered=$(state_get last_registration_timestamp)
wipe_ok=$(state_get last_wipe_ok)

now_ns="$(date +%s)000000000"
payload=$(jq -nc \
  --arg host "$host" --arg ts "$now_ns" \
  --arg daemon "$daemon_up" --arg runner "$runner_up" --arg registered "$registered" --arg wipe "$wipe_ok" '
  def gauge(name; desc; v): {name: name, description: desc, gauge: {dataPoints: [{timeUnixNano: $ts, asInt: v}]}};
  {resourceMetrics: [{
    resource: {attributes: [
      {key: "service.name", value: {stringValue: "ci-runner"}},
      {key: "host.name", value: {stringValue: $host}}
    ]},
    scopeMetrics: [{
      scope: {name: "io.olympus.ci-runner-heartbeat"},
      metrics: (
        [gauge("ci_runner_daemon_up"; "1 while the CI runner loop LaunchDaemon is running"; $daemon),
         gauge("ci_runner_runner_up"; "1 while a registered runner of the runner user is running"; $runner)]
        + (if $registered == "" then [] else
            [gauge("ci_runner_last_registration_timestamp_seconds"; "Unix time of the last successful JIT registration"; $registered)] end)
        + (if $wipe == "" then [] else
            [gauge("ci_runner_last_wipe_ok"; "1 if the last wipe of the runner user succeeded, 0 if it failed"; $wipe)] end)
      )
    }]
  }]}')

if ! printf '%s' "$payload" | curl --silent --show-error --fail --max-time 10 \
  -H 'Content-Type: application/json' --data-binary @- "${CI_HB_ENDPOINT%/}/v1/metrics" >/dev/null; then
  log "could not push to ${CI_HB_ENDPOINT%/}/v1/metrics"
  exit 1
fi
