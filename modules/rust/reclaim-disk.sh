#!/usr/bin/env bash
#
# reclaim-disk — on-demand disk reclamation for a dev Mac.
#
# Templated to ~/.local/bin/reclaim-disk by home-manager (modules/rust/rust.nix).
# NOT scheduled — run it by hand when you need space back:  reclaim-disk
#
# The AUTOMATIC section only removes regenerable build output and package
# caches (Rust target dirs, npm/pnpm caches). Nothing here touches source code,
# git history, or emulators/simulators. The MANUAL section lists bigger,
# judgement-call wins and is left commented out on purpose.
#
set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

human()  { du -sh "$1" 2>/dev/null | cut -f1; }
note()   { printf '  %-48s %s\n' "$1" "$2"; }
run()    { if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

CARGO_TARGET_DIR_DEFAULT="$HOME/.cache/cargo/target"
PROJECTS="$HOME/projects"

echo "Disk before:"
df -h / | awk 'NR==1 || /\/$/'
[ "$DRY_RUN" = 1 ] && echo "(dry run — nothing will be deleted)"
echo

echo "== Top space users in \$HOME (informational) =="
du -h -d 1 "$HOME" 2>/dev/null | sort -hr | head -12
echo

# ---------------------------------------------------------------------------
# AUTOMATIC — regenerable only. Safe.
# ---------------------------------------------------------------------------
echo "== Rust build artifacts (usually the biggest win) =="
# Shared target dir (set by home-manager via CARGO_TARGET_DIR).
shared="${CARGO_TARGET_DIR:-$CARGO_TARGET_DIR_DEFAULT}"
if [ -d "$shared" ]; then
  note "shared target dir" "$(human "$shared")"
  run "rm -rf \"$shared\""
fi
# Any per-project target/ dirs left over from before the shared dir, or from
# projects that override CARGO_TARGET_DIR.
if [ -d "$PROJECTS" ]; then
  while IFS= read -r d; do
    note "rm target" "$(human "$d")  ($d)"
    run "rm -rf \"$d\""
  done < <(find "$PROJECTS" -type d -name target -prune 2>/dev/null)
fi
echo

echo "== JS package caches (regenerable) =="
if command -v npm >/dev/null 2>&1; then
  note ".npm cache" "$(human "$HOME/.npm")"
  run "npm cache clean --force >/dev/null 2>&1 || true"
fi
if command -v pnpm >/dev/null 2>&1; then
  note "pnpm store prune" "$(human "$(pnpm store path 2>/dev/null)")"
  run "pnpm store prune >/dev/null 2>&1 || true"
fi
# Stray .pnpm-store dirs inside projects (older pnpm layouts).
if [ -d "$PROJECTS" ]; then
  while IFS= read -r d; do
    note "rm .pnpm-store" "$(human "$d")  ($d)"
    run "rm -rf \"$d\""
  done < <(find "$PROJECTS" -type d -name .pnpm-store -prune 2>/dev/null)
fi
echo

echo "Disk after automatic cleanup:"
df -h / | awk '/\/$/'
echo

# ---------------------------------------------------------------------------
# MANUAL — bigger wins that need YOUR judgement. Uncomment to enable.
# ---------------------------------------------------------------------------
cat <<'NOTES'
Not run automatically — decide per machine, then uncomment:

  # Gradle dependency cache (safe, forces one slow Android rebuild):
  #   rm -rf ~/.gradle/caches

  # Xcode DerivedData (safe, forces one slow iOS rebuild; simulators untouched):
  #   rm -rf ~/Library/Developer/Xcode/DerivedData/*

  # Unused Android system images / AVDs — prune via Android Studio > SDK Manager.
  #   Do NOT delete the image/AVD an active project's emulator targets.

  # Standalone Android emulators you no longer use (e.g. MuMu, BlueStacks):
  #   uninstall the app, then remove its ~/Library/"Application Support"/<id> dir.

  # git worktrees in active repos — leave these to the coding agent working in
  # that repo; it can tell needed work from stale. Do not bulk-remove.
NOTES
