# Remove the session-contract block the old nix harness kept at the end of each Claude dir's global CLAUDE.md.
# Activation script for home/cli/claude/harness.nix (wrapped by writeShellApplication: bash, set -euo pipefail).
#
#   contract-unwire <name> <CLAUDE.md>...
#
# The contract now comes from the agent-harness plugin's SessionStart hook (olympus-sdk#753, design P5), so the
# block between
#   <!-- agent-skills:<name>:start ... -->  and  <!-- agent-skills:<name>:end -->
# is dropped, with the blank lines left trailing before it. Everything else is the owner's and is kept byte for
# byte. A file without the block, a missing file and a symlinked file are left alone. A file that held only the
# block is left empty. Idempotent: an unchanged file is not rewritten.

name="$1"
shift

start="<!-- agent-skills:${name}:start"
end="<!-- agent-skills:${name}:end -->"

for target in "$@"; do
  [ -f "$target" ] || continue
  if [ -L "$target" ]; then
    echo "contract-unwire: $target is a symlink; not touching it" >&2
    continue
  fi
  grep -qF -- "$start" "$target" || continue
  tmp="$(mktemp "${target}.XXXXXX")"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { lines[++n] = $0 }
    END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
  ' "$target" >"$tmp"
  # Rewrite in place so the owner's mode and inode are kept.
  cat "$tmp" >"$target"
  rm -f "$tmp"
  echo "contract-unwire: removed the ${name} block from $target"
done
