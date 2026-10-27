# Keep one hook entry of ours in each Claude dir's settings.json.
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   hook-wire <event> <matcher> <identity-regex> <command> <settings.json>...
#
# Claude Code owns and rewrites settings.json, so this never replaces the file from nix. It edits only
# .hooks.<event> with jq, the same way home/cli/memory/wire.sh does:
#   - a hook group is "ours" when any of its hooks has a command matching <identity-regex> (so a previous store
#     path, or a hand-installed copy, is replaced instead of doubled);
#   - the first of our groups becomes {"matcher": <matcher>, "hooks": [{"type": "command", "command": <command>}]},
#     any other group of ours vanishes, and a group that mixes our hook with someone else's keeps theirs;
#   - no group of ours yet: ours is appended after the existing ones;
#   - every other key, event and group is left exactly as it was.
# Idempotent (a second run writes nothing), fail-soft (a file that cannot be parsed is reported and left
# untouched; the exit status is 0 unless the arguments are wrong). A missing settings.json is created as {}.

warn() { printf 'hook-wire: warning: %s\n' "$*" >&2; }
info() { printf 'hook-wire: %s\n' "$*" >&2; }

if [ $# -lt 5 ]; then
  echo "usage: hook-wire <event> <matcher> <identity-regex> <command> <settings.json>..." >&2
  exit 2
fi
event="$1" matcher="$2" re="$3" command="$4"
shift 4

# shellcheck disable=SC2016  # jq program is single-quoted on purpose
JQ='
def cmd: (.command? // "") | if type == "string" then . else "" end;
def ours_hook: cmd | test($re);
def ours: type == "object" and ((.hooks? | type) == "array") and any(.hooks[]?; ours_hook);
def place($arr; $g):
  (reduce $arr[] as $x ({out: [], done: false};
     if ($x | ours) then
       ($x | .hooks |= map(select(ours_hook | not))) as $s
       | (if ($s.hooks | length) > 0 then .out += [$s] else . end)
       | (if .done then . else (.out += [$g] | .done = true) end)
     else .out += [$x] end)) as $r
  | if $r.done then $r.out else $r.out + [$g] end;
.hooks = ((.hooks // {}) | if type == "object" then . else error("hooks is not an object") end)
| .hooks[$ev] = place((.hooks[$ev] // []) | if type == "array" then . else error("hooks.\($ev) is not an array") end; $g)
'

wire_one() { # settings.json
  local file="$1" src tmp mode
  if [ -e "$file" ] && [ ! -f "$file" ]; then
    warn "$file is not a regular file; skipped"
    return 0
  fi
  src="$file"
  if [ ! -e "$file" ]; then
    src=$(mktemp)
    printf '{}\n' >"$src"
  fi
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "$(dirname "$file")/.hook-wire.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
  if ! jq --arg re "$re" --arg ev "$event" --argjson g "$group" "$JQ" "$src" >"$tmp" 2>"$tmp.err"; then
    warn "$file left untouched: $(head -n 1 "$tmp.err" 2>/dev/null)"
    rm -f "$tmp" "$tmp.err"
    [ "$src" = "$file" ] || rm -f "$src"
    return 0
  fi
  rm -f "$tmp.err"
  if [ -e "$file" ] && jq -e --slurpfile o "$file" '. == $o[0]' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  if [ -e "$file" ]; then
    mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || echo 644)
  else
    mode=644
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$file"
  [ "$src" = "$file" ] || rm -f "$src"
  info "updated $file"
}

group=$(jq -cn --arg m "$matcher" --arg c "$command" '{matcher: $m, hooks: [{type: "command", command: $c}]}')

for f in "$@"; do
  wire_one "$f" || warn "$f: hook not wired"
done
