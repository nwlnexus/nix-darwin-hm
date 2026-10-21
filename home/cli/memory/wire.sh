#!/usr/bin/env bash
# memory-wire: merge (or remove) the memory-gateway client wiring in Claude Code's own files.
#
# Claude Code owns and mutates <config dir>/settings.json and the account's .claude.json, so home-manager must
# not replace them. This script edits only the entries the nix module manages and leaves every other key alone:
#
#   settings.json  .hooks.{SessionStart,Stop,PreCompact,SessionEnd}  hook groups whose command runs
#                  memory-capture / memory-session-start (design 11: that match is the identity of "ours",
#                  so a previous store path, or a hand-installed copy, is replaced instead of doubled)
#   .claude.json   .mcpServers.memory  only when its headersHelper runs memory-mcp-headers (a `memory` server
#                  anyone else defined is left alone and reported)
#
# Usage:
#   memory-wire apply  --spec SPEC.json --manifest MANIFEST.json
#   memory-wire remove --manifest MANIFEST.json
#
# SPEC.json: {"targets":[{"name","settings","mcp","hooks":{"<Event>":<hook group>,...},"mcpServer":{...}}]}
# MANIFEST.json (written here): {"targets":[{"settings","mcp"}]}, the files this script has wired. `apply` removes
# the managed entries from targets that left the spec, `remove` removes them from every recorded target (so
# disabling the module cleans up after itself), then deletes the manifest.
#
# Idempotent (a second run writes nothing), fail-soft (a file that cannot be parsed is reported and left
# untouched; the exit status is 0 unless the arguments are wrong) and silent about secrets (none pass through
# here: the spec holds paths and commands only).
set -euo pipefail

HOOK_RE='memory-(capture|session-start)'
MCP_TAG='memory-mcp-headers'

warn() { printf 'memory-wire: warning: %s\n' "$*" >&2; }
info() { printf 'memory-wire: %s\n' "$*" >&2; }

# Shared jq definitions. A hook group is "ours" when any of its hooks runs one of our scripts.
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose
JQ_DEFS='
def cmd: (.command? // "") | if type == "string" then . else "" end;
def ours_hook: cmd | test($re);
def ours: (.hooks? | type) == "array" and any(.hooks[]?; ours_hook);
# One event array with our groups replaced: the first of our groups becomes $g (if given), the others vanish,
# and a group that mixes our hook with someone elses keeps theirs. No group of ours: $g is appended.
def place($arr; $g):
  ($arr
   | map(if ours
         then (.hooks |= map(select(ours_hook | not))) as $s
              | (if ($s.hooks | length) == 0 then [{"__slot": true}] else [$s, {"__slot": true}] end)
         else [.] end)
   | add // []) as $p
  | if any($p[]; type == "object" and (.__slot? == true)) then
      (reduce $p[] as $x ({out: [], done: false};
         if ($x | type) == "object" and ($x.__slot? == true)
         then (if .done or ($g == null) then . else (.out += [$g] | .done = true) end)
         else .out += [$x] end) | .out)
    elif $g == null then $p
    else $p + [$g] end;
def apply_hooks($want):
  . as $orig
  | reduce ($want | keys_unsorted[]) as $ev (.;
      .hooks = ((.hooks // {}) | if type == "object" then . else error("hooks is not an object") end)
      | .hooks[$ev] = place((.hooks[$ev] // []) | if type == "array" then . else error("hooks.\($ev) is not an array") end; $want[$ev]))
  | reduce ((.hooks | keys_unsorted[]) | select(. as $e | ($want | has($e) | not))) as $ev (.;
      if (.hooks[$ev] | type) == "array" and any(.hooks[$ev][]; ours)
      then (place(.hooks[$ev]; null)) as $n
           | if ($n | length) == 0 then del(.hooks[$ev]) else .hooks[$ev] = $n end
      else . end);
def remove_hooks:
  . as $orig
  | if (.hooks? | type) != "object" then .
    else
      reduce (.hooks | keys_unsorted[]) as $ev (.;
        if (.hooks[$ev] | type) == "array" and any(.hooks[$ev][]; ours)
        then (place(.hooks[$ev]; null)) as $n
             | if ($n | length) == 0 then del(.hooks[$ev]) else .hooks[$ev] = $n end
        else . end)
      | if . != $orig and .hooks == {} then del(.hooks) else . end
    end;
def mcp_ours: (.mcpServers.memory? // null) as $m
  | $m != null and ($m | type) == "object" and (($m.headersHelper? // "") | tostring | contains($tag));
def mcp_foreign: (.mcpServers.memory? // null) as $m | $m != null and (mcp_ours | not);
'

# jq_edit FILE CREATE_MODE FILTER [jq args...]: run FILTER over FILE and replace it only when the JSON changed.
# FILE absent: created (as {}) with CREATE_MODE when CREATE_MODE is not "-", else skipped. Returns 1 on failure.
jq_edit() {
  local file="$1" create="$2" filter="$3"
  shift 3
  local src="$file" tmp mode
  if [ ! -e "$file" ]; then
    [ "$create" != "-" ] || return 0
    src=$(mktemp)
    printf '{}\n' >"$src"
  elif [ ! -f "$file" ]; then
    warn "$file is not a regular file; skipped"
    return 1
  fi
  tmp=$(mktemp "$(dirname "$file")/.memory-wire.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
  if ! jq --arg re "$HOOK_RE" --arg tag "$MCP_TAG" "$@" "$JQ_DEFS $filter" "$src" >"$tmp" 2>"$tmp.err"; then
    warn "$file left untouched: $(head -n 1 "$tmp.err" 2>/dev/null)"
    rm -f "$tmp" "$tmp.err"
    [ "$src" = "$file" ] || rm -f "$src"
    return 1
  fi
  rm -f "$tmp.err"
  if [ -e "$file" ] && jq -e --slurpfile o "$file" '. == $o[0]' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$file" ]; then
    mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || echo 600)
  else
    mode=$create
  fi
  chmod "$mode" "$tmp"
  mkdir -p "$(dirname "$file")"
  mv "$tmp" "$file"
  [ "$src" = "$file" ] || rm -f "$src"
  info "updated $file"
}

apply_target() { # SPEC_TARGET_JSON
  local t="$1" name settings mcp
  name=$(jq -r '.name' <<<"$t")
  settings=$(jq -r '.settings' <<<"$t")
  mcp=$(jq -r '.mcp' <<<"$t")
  # shellcheck disable=SC2016
  jq_edit "$settings" 644 'apply_hooks($want)' --argjson want "$(jq -c '.hooks' <<<"$t")" ||
    warn "$name: hooks not wired in $settings"
  if [ -f "$mcp" ] && jq -e --arg re "$HOOK_RE" --arg tag "$MCP_TAG" "$JQ_DEFS mcp_foreign" "$mcp" >/dev/null 2>&1; then
    warn "$name: $mcp already has an mcpServers.memory that is not ours; left alone"
    return 0
  fi
  # shellcheck disable=SC2016
  jq_edit "$mcp" 600 '.mcpServers = ((.mcpServers // {}) | if type == "object" then . else error("mcpServers is not an object") end) | .mcpServers.memory = $srv' \
    --argjson srv "$(jq -c '.mcpServer' <<<"$t")" ||
    warn "$name: MCP server not wired in $mcp"
}

remove_hooks_from() { # SETTINGS
  [ -f "$1" ] || return 0
  jq_edit "$1" - 'remove_hooks' || warn "could not clean hooks in $1"
}

remove_mcp_from() { # MCP_FILE
  [ -f "$1" ] || return 0
  if jq -e --arg re "$HOOK_RE" --arg tag "$MCP_TAG" "$JQ_DEFS mcp_ours" "$1" >/dev/null 2>&1; then
    jq_edit "$1" - 'del(.mcpServers.memory) | if (.mcpServers == {}) then del(.mcpServers) else . end' ||
      warn "could not remove mcpServers.memory from $1"
  fi
}

previous_targets() { # MANIFEST -> JSON array on stdout
  if [ -f "$1" ] && jq -e '.targets | type == "array"' "$1" >/dev/null 2>&1; then
    jq -c '.targets' "$1"
  else
    echo '[]'
  fi
}

main() {
  local action="${1:-}" spec="" manifest=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec="${2:?--spec needs a file}"; shift 2 ;;
      --manifest) manifest="${2:?--manifest needs a file}"; shift 2 ;;
      *) echo "memory-wire: unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$manifest" ] || { echo "memory-wire: --manifest is required" >&2; exit 2; }
  case "$action" in
    apply) [ -n "$spec" ] || { echo "memory-wire: apply needs --spec" >&2; exit 2; } ;;
    remove) ;;
    *) echo "usage: memory-wire apply --spec FILE --manifest FILE | remove --manifest FILE" >&2; exit 2 ;;
  esac

  local prev cur_settings cur_mcp
  prev=$(previous_targets "$manifest")

  if [ "$action" = remove ]; then
    jq -c '.[]' <<<"$prev" | while IFS= read -r t; do
      remove_hooks_from "$(jq -r '.settings' <<<"$t")"
      remove_mcp_from "$(jq -r '.mcp' <<<"$t")"
    done
    rm -f "$manifest"
    return 0
  fi

  jq -e '.targets | type == "array"' "$spec" >/dev/null || { echo "memory-wire: bad spec $spec" >&2; exit 2; }
  cur_settings=$(jq -c '[.targets[].settings]' "$spec")
  cur_mcp=$(jq -c '[.targets[].mcp]' "$spec")

  # Targets that left the spec (account removed or renamed): take our entries back out.
  jq -c '.[]' <<<"$prev" | while IFS= read -r t; do
    s=$(jq -r '.settings' <<<"$t")
    m=$(jq -r '.mcp' <<<"$t")
    jq -e --arg s "$s" 'index($s) != null' <<<"$cur_settings" >/dev/null || remove_hooks_from "$s"
    jq -e --arg m "$m" 'index($m) != null' <<<"$cur_mcp" >/dev/null || remove_mcp_from "$m"
  done

  jq -c '.targets[]' "$spec" | while IFS= read -r t; do
    apply_target "$t"
  done

  mkdir -p "$(dirname "$manifest")"
  jq '{targets: [.targets[] | {settings, mcp}]}' "$spec" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
}

main "$@"
