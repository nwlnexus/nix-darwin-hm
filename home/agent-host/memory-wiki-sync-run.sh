# Runs memory-wiki-sync (shipped by the olympus-memory plugin) for the personal accounts. Wrapped by
# writeShellApplication (set -euo pipefail; jq, coreutils, awk, grep on PATH).
#   memory-wiki-sync-run [memory-wiki-sync args...]
# MEMORY_WIKI_SYNC_ACCOUNTS: space-separated account names (config dirs ~/.claude-<name>); the plugin is looked up in
# the first one that has it installed. SECOND_BRAIN_PATH: the wiki checkout. A host without the plugin or without the
# checkout yet skips quietly (exit 0): the next timer run retries.
: "${MEMORY_WIKI_SYNC_ACCOUNTS:?MEMORY_WIKI_SYNC_ACCOUNTS is not set}"
: "${SECOND_BRAIN_PATH:?SECOND_BRAIN_PATH is not set}"

log() { printf 'memory-wiki-sync-run: %s\n' "$*" >&2; }

roots=""
script=""
for acct in $MEMORY_WIKI_SYNC_ACCOUNTS; do
  dir="$HOME/.claude-$acct"
  roots="${roots:+$roots:}$dir/projects"
  if [ -z "$script" ] && [ -r "$dir/plugins/installed_plugins.json" ]; then
    root="$(jq -r '.plugins["olympus-memory@olympus-private"][0].installPath // empty' "$dir/plugins/installed_plugins.json")"
    if [ -n "$root" ] && [ -x "$root/memory-hooks/bin/memory-wiki-sync" ]; then
      script="$root/memory-hooks/bin/memory-wiki-sync"
    fi
  fi
done

if [ -z "$script" ]; then
  log "olympus-memory plugin with memory-wiki-sync is not installed for: $MEMORY_WIKI_SYNC_ACCOUNTS; skipping"
  exit 0
fi
if [ ! -d "$SECOND_BRAIN_PATH/raw" ]; then
  log "no second-brain checkout at $SECOND_BRAIN_PATH yet; skipping"
  exit 0
fi

export MEMORY_WIKI_SYNC_ROOTS="$roots"
exec "$script" "$@"
