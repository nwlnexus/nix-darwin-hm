# Declare the Claude Code plugin marketplaces and enabled plugins in one Claude dir's settings.json, and take out
# the hook entries the old nix harness wired (olympus-sdk#753, design P13/P14).
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   plugin-wire <spec.json> <settings.json>...
#
# <spec.json>: {"marketplaces": {<name>: <extraKnownMarketplaces entry>}, "enable": {<plugin id>: true},
#               "removeHookCommands": [<exact hook command>...]}
# Claude Code owns and rewrites settings.json, so this never replaces the file from nix. With jq it
#   - sets each named entry of .extraKnownMarketplaces and .enabledPlugins (other entries are kept: a marketplace or
#     plugin added by hand stays, and a plugin the owner set to false is set back to true only if the spec names it);
#   - drops every hook whose command is one of removeHookCommands, then any group and event left empty;
#   - leaves every other key exactly as it was.
# Claude Code clones a declared marketplace it has not fetched yet in the background after the session starts and
# downloads the enabled plugins; they load from the next session or /reload-plugins.
# Idempotent (a second run writes nothing), fail-soft (a file that cannot be parsed is reported and left
# untouched; the exit status is 0 unless the arguments are wrong). A missing settings.json is created as {}.

warn() { printf 'plugin-wire: warning: %s\n' "$*" >&2; }
info() { printf 'plugin-wire: %s\n' "$*" >&2; }

if [ $# -lt 2 ]; then
  echo "usage: plugin-wire <spec.json> <settings.json>..." >&2
  exit 2
fi
spec_file="$1"
shift

if ! spec=$(jq -ce '
  if type == "object"
     and ((.marketplaces // {}) | type) == "object"
     and ((.enable // {}) | type) == "object"
     and ((.removeHookCommands // []) | type == "array" and all(.[]; type == "string"))
  then {marketplaces: (.marketplaces // {}), enable: (.enable // {}), removeHookCommands: (.removeHookCommands // [])}
  else error("bad spec") end' "$spec_file" 2>/dev/null); then
  warn "$spec_file is not a valid spec; nothing wired"
  exit 0
fi

# shellcheck disable=SC2016  # jq program is single-quoted on purpose
JQ='
def obj($k): (.[$k] // {}) | if type == "object" then . else error("\($k) is not an object") end;
def drop_hooks:
  if (.hooks? | type) != "object" or ($spec.removeHookCommands | length) == 0 then .
  else
    . as $orig
    | .hooks |= with_entries(
        if (.value | type) == "array" then
          .value |= (map(
              if type == "object" and ((.hooks? | type) == "array") then
                (.hooks | length) as $n
                | .hooks |= map(select(((.command? // "") as $c | $spec.removeHookCommands | index($c)) | not))
                | if $n > 0 and (.hooks | length) == 0 then empty else . end
              else . end))
        else . end)
    | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0 or (($orig.hooks[.key] | length) == 0)))
    | if .hooks == {} and $orig.hooks != {} then del(.hooks) else . end
  end;
.extraKnownMarketplaces = (obj("extraKnownMarketplaces") + $spec.marketplaces)
| .enabledPlugins = (obj("enabledPlugins") + $spec.enable)
| drop_hooks
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
  tmp=$(mktemp "$(dirname "$file")/.plugin-wire.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
  if ! jq --argjson spec "$spec" "$JQ" "$src" >"$tmp" 2>"$tmp.err"; then
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

for f in "$@"; do
  wire_one "$f" || warn "$f: plugins not wired"
done
