# Keep the agent-skills session contract in a marked block of each Claude dir's global CLAUDE.md.
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   contract-wire <name> <fragment.md> <CLAUDE.md>...
#
# The fragment's YAML frontmatter is dropped and its body written between
#   <!-- agent-skills:<name>:start ... -->  and  <!-- agent-skills:<name>:end -->
# at the end of each CLAUDE.md. Everything outside the markers is the owner's and is kept byte for byte (only
# trailing blank lines before the block are normalised to one). Claude Code strips HTML comments from CLAUDE.md
# before it reaches the model, so the markers cost no context. Idempotent: an unchanged file is not rewritten.
# A missing CLAUDE.md is created; a symlinked one (someone else manages it) is left alone with a warning.

name="$1"
fragment="$2"
shift 2

start="<!-- agent-skills:${name}:start (managed by nix-darwin-hm from nwlnexus/agent-skills fragments/${name}.md; edit it there, changes here are overwritten) -->"
end="<!-- agent-skills:${name}:end -->"

body="$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm { print }' "$fragment" |
  awk 'NF { seen = 1 } seen { print }')"
if [ -z "$body" ]; then
  echo "contract-wire: $fragment has no body; nothing to write" >&2
  exit 1
fi

for target in "$@"; do
  if [ -L "$target" ]; then
    echo "contract-wire: $target is a symlink; not touching it" >&2
    continue
  fi
  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "${target}.XXXXXX")"
  if [ -f "$target" ]; then
    # Drop any earlier managed block (start marker line through end marker line), then trailing blank lines.
    awk -v s="<!-- agent-skills:${name}:start" -v e="$end" '
      index($0, s) == 1 { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { lines[++n] = $0 }
      END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
    ' "$target" >"$tmp"
  fi
  sep=""
  if [ -s "$tmp" ]; then sep=$'\n'; fi
  printf '%s%s\n%s\n%s\n' "$sep" "$start" "$body" "$end" >>"$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    continue
  fi
  if [ -f "$target" ]; then
    # Rewrite in place so the owner's mode and inode are kept.
    cat "$tmp" >"$target"
    rm -f "$tmp"
  else
    chmod 0644 "$tmp"
    mv "$tmp" "$target"
  fi
  echo "contract-wire: updated $target"
done
