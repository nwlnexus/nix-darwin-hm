# Keep the nix-owned permission rules and auto-mode config in each Claude dir's settings.json.
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   settings-wire <allow.json> <auto-mode.json | -> <settings.json>...
#
# <allow.json> is a JSON array of permission rules; <auto-mode.json> is a JSON object, or `-` to leave
# .autoMode alone. Claude Code owns and rewrites settings.json, so this never replaces the file from nix. It edits
# two keys with jq, the same way ./hook-wire.sh and home/cli/memory/wire.sh do:
#   - .permissions.allow: every rule of <allow.json> that is missing is appended, in order; nothing is ever
#     removed or reordered (a rule added by hand or by Claude Code stays);
#   - .autoMode: replaced as a whole by <auto-mode.json> (nix owns that key), unless `-` was given;
#   - every other key is left exactly as it was.
# Idempotent (a second run writes nothing), fail-soft (a file that cannot be parsed is reported and left
# untouched; the exit status is 0 unless the arguments are wrong). A missing settings.json is created as {}.

warn() { printf 'settings-wire: warning: %s\n' "$*" >&2; }
info() { printf 'settings-wire: %s\n' "$*" >&2; }

if [ $# -lt 3 ]; then
  echo "usage: settings-wire <allow.json> <auto-mode.json | -> <settings.json>..." >&2
  exit 2
fi
allow_file="$1" auto_file="$2"
shift 2

if ! allow=$(jq -ce 'if type == "array" and all(.[]; type == "string") then . else error("not an array of strings") end' "$allow_file" 2>/dev/null); then
  warn "$allow_file is not a JSON array of strings; nothing wired"
  exit 0
fi
if [ "$auto_file" = - ]; then
  auto=null
elif ! auto=$(jq -ce 'if type == "object" then . else error("not an object") end' "$auto_file" 2>/dev/null); then
  warn "$auto_file is not a JSON object; nothing wired"
  exit 0
fi

# shellcheck disable=SC2016  # jq program is single-quoted on purpose
JQ='
.permissions = ((.permissions // {}) | if type == "object" then . else error("permissions is not an object") end)
| .permissions.allow = (
    (.permissions.allow // []) | if type == "array" then . else error("permissions.allow is not an array") end
    | reduce $allow[] as $r (.; if any(.[]; . == $r) then . else . + [$r] end))
| if $auto == null then . else .autoMode = $auto end
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
  tmp=$(mktemp "$(dirname "$file")/.settings-wire.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
  if ! jq --argjson allow "$allow" --argjson auto "$auto" "$JQ" "$src" >"$tmp" 2>"$tmp.err"; then
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
  wire_one "$f" || warn "$f: settings not wired"
done
