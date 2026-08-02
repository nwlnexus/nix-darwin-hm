#!/usr/bin/env bash
#
# darwin-rebuild.sh
#
# Host-portable wrapper around `darwin-rebuild` that works whether this repo
# lives on the boot volume (laptop) or on an external drive (the desktop
# hosts, where ~/projects is a symlink to e.g. /Volumes/REALTEK/projects).
#
#   ./scripts/darwin-rebuild.sh switch [host] [extra darwin-rebuild args...]
#   ./scripts/darwin-rebuild.sh build  [host]
#   ./scripts/darwin-rebuild.sh check  [host]
#
# WHY THIS EXISTS
#
# `sudo darwin-rebuild switch --flake .` evaluates as root. Nix resolves a
# bare path inside a git repo through its libgit2 `git+file://` fetcher, and
# libgit2 refuses to open a repository whose owner it does not recognise:
#
#   error: opening Git repository "/Volumes/REALTEK/projects/personal/nix-darwin-hm":
#          repository path ... is not owned by current user (libgit2 error code = 7)
#
# External drives are mounted `noowners` on macOS (confirm with
# `mount | grep <volume>`), which is what trips the check there but not on the
# boot volume. `darwin-rebuild` also resets HOME=~root when euid is 0, so a
# `safe.directory` entry in YOUR git config is never consulted during a root
# rebuild — it has to live in root's own config (see `just git-safe-directory`).
#
# The fix used here is to hand Nix a `path:` flake reference on affected
# hosts, which bypasses the git fetcher entirely. Verified to produce a
# byte-identical system closure to the git+file build.
#
# Notes:
# - `build` and `switch` deliberately use the SAME flake reference. The git
#   and path fetchers hash their sources differently, so mixing them means a
#   `build` never warms the cache for the following `switch`.
# - `path:` copies the whole working tree into the store, including
#   gitignored files. That is the cost of the workaround; `git-safe-directory`
#   is the way to opt back into the leaner git fetcher.
# - Detection is belt-and-braces: we pick `path:` up front when the volume is
#   `noowners`, and still fall back automatically if the ownership error shows
#   up anyway on a host that mounts its drive differently.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") {switch|build|check} [host] [extra args...]" >&2
}

action="${1:-switch}"
[ $# -gt 0 ] && shift

case "$action" in
  switch | build | check) ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

# A leading non-flag argument is the host name; otherwise default to this
# machine's short hostname. An empty first argument is treated as absent so
# justfile recipes can pass through an unset `host` parameter.
if [ $# -gt 0 ] && [ -n "$1" ] && [ "${1#-}" = "$1" ]; then
  host="$1"
  shift
else
  [ $# -gt 0 ] && [ -z "$1" ] && shift
  # Matches darwin-rebuild's own default. LocalHostName is stable, whereas
  # `hostname -s` can drift to whatever DHCP hands back.
  host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Fail fast on an unknown host rather than after a long eval or a wasted sudo
# prompt. Listing attrNames is cheap; evaluating .system would not be.
hosts="$(nix eval --raw "${repo_dir}#darwinConfigurations" \
  --apply 'x: builtins.concatStringsSep " " (builtins.attrNames x)' 2>/dev/null || true)"
if [ -n "$hosts" ] && ! printf '%s\n' $hosts | grep -qx -- "$host"; then
  echo "no darwinConfigurations.\"${host}\" in this flake." >&2
  echo "available: ${hosts}" >&2
  echo "pass one explicitly: $(basename "$0") ${action} <host>" >&2
  exit 1
fi

# Is the repo on a volume mounted `noowners`? That is the marker for the
# libgit2 ownership failure under sudo.
mount_point="$(df -P "$repo_dir" | awk 'NR==2 {out=$6; for (i=7; i<=NF; i++) out = out OFS $i; print out}')"
git_ref="${repo_dir}#${host}"
path_ref="path:${repo_dir}#${host}"

if mount | grep -F " on ${mount_point} " | grep -q noowners; then
  echo "note: ${mount_point} is mounted noowners — using a path: flake ref so the"
  echo "      root evaluation does not go through libgit2."
  echo "      (\`just git-safe-directory\` may let you drop this; see that recipe.)"
  flake_ref="$path_ref"
else
  flake_ref="$git_ref"
fi

# Bootstrap rebuilds need the GitHub PAT in the ROOT eval's nix config, before
# system/nix.nix's `!include` of /etc/nix/github-token.conf is live. Callers
# set DARWIN_REBUILD_NIX_CONFIG; see the darwin-rebuild-bootstrap recipe.
run() {
  local ref="$1"
  shift
  if [ "$action" = build ]; then
    # Building needs no privileges, and staying unprivileged sidesteps the
    # ownership check entirely.
    darwin-rebuild build --flake "$ref" "$@"
  elif [ -n "${DARWIN_REBUILD_NIX_CONFIG:-}" ]; then
    sudo NIX_CONFIG="$DARWIN_REBUILD_NIX_CONFIG" darwin-rebuild "$action" --flake "$ref" "$@"
  else
    sudo darwin-rebuild "$action" --flake "$ref" "$@"
  fi
}

# Explicit template: BSD and GNU mktemp disagree about bare `-t` prefixes.
log="$(mktemp "${TMPDIR:-/tmp}/darwin-rebuild.XXXXXX")"
trap 'rm -f "$log"' EXIT

set +e
run "$flake_ref" "$@" 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"
set -e

if [ "$rc" -ne 0 ] \
  && [ "$flake_ref" != "$path_ref" ] \
  && grep -q 'is not owned by current user' "$log"; then
  echo
  echo "libgit2 refused the repo under root — retrying with a path: flake ref."
  set +e
  run "$path_ref" "$@" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"
  set -e
fi

exit "$rc"
