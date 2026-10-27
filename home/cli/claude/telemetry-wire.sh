# Keep the nix-owned telemetry environment in one Claude dir's settings.json `env` block.
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   telemetry-wire <env.json> <settings.json>
#
# <env.json> is a JSON object of string values (CLAUDE_CODE_ENABLE_TELEMETRY, OTEL_*; olympus-sdk#565). Claude Code
# owns and rewrites settings.json, so this never replaces the file from nix: it sets exactly the keys of <env.json>
# in `.env` (an existing value of one of those keys is replaced, nix owns them) and leaves every other key,
# including other `.env` entries, exactly as it was. Claude Code reads `env` from settings.json at startup for
# interactive, headless (`-p`) and Remote Control sessions alike, which is why the telemetry lives here and not
# in a shell profile or one service unit.
# Idempotent (a second run writes nothing), fail-soft (a file that cannot be parsed is reported and left
# untouched; the exit status is 0 unless the arguments are wrong). A missing settings.json is created as {}.

warn() { printf 'telemetry-wire: warning: %s\n' "$*" >&2; }
info() { printf 'telemetry-wire: %s\n' "$*" >&2; }

if [ $# -ne 2 ]; then
  echo "usage: telemetry-wire <env.json> <settings.json>" >&2
  exit 2
fi
env_file="$1" file="$2"

if ! envs=$(jq -ce 'if type == "object" and all(.[]; type == "string") then . else error("not an object of strings") end' "$env_file" 2>/dev/null); then
  warn "$env_file is not a JSON object of strings; nothing wired"
  exit 0
fi

# shellcheck disable=SC2016  # jq program is single-quoted on purpose
JQ='
.env = ((.env // {}) | if type == "object" then . else error("env is not an object") end)
| .env += $envs
'

if [ -e "$file" ] && [ ! -f "$file" ]; then
  warn "$file is not a regular file; skipped"
  exit 0
fi
src="$file"
if [ ! -e "$file" ]; then
  src=$(mktemp)
  printf '{}\n' >"$src"
fi
mkdir -p "$(dirname "$file")"
tmp=$(mktemp "$(dirname "$file")/.telemetry-wire.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
if ! jq --argjson envs "$envs" "$JQ" "$src" >"$tmp" 2>"$tmp.err"; then
  warn "$file left untouched: $(head -n 1 "$tmp.err" 2>/dev/null)"
  rm -f "$tmp" "$tmp.err"
  [ "$src" = "$file" ] || rm -f "$src"
  exit 0
fi
rm -f "$tmp.err"
if [ -e "$file" ] && jq -e --slurpfile o "$file" '. == $o[0]' "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"
  exit 0
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
