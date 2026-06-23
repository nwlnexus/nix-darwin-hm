#!/usr/bin/env bash
#
# export-iterm-profile.sh
#
# Capture THIS host's current iTerm2 *default* profile and write it into the
# repo as home/apps/iterm2/profile.json, so your live settings become the
# version-controlled template that nix activation deploys to every other host.
#
# Run this on the host whose iTerm2 look-and-feel you want to standardize on:
#
#   ./scripts/export-iterm-profile.sh
#   nix fmt && git add home/apps/iterm2/profile.json && git commit -m "chore(iterm2): refresh profile template"
#
# Notes:
# - Reads the live prefs via `defaults export`, so quit iTerm2 first if you
#   just changed settings (iTerm2 flushes prefs on quit).
# - The Name / Guid / Custom Command / Command keys are intentionally NOT
#   exported; those are injected by home/apps/iterm2/default.nix so the tmux
#   launch behavior stays under Nix control.

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: this script only runs on macOS." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${repo_root}/home/apps/iterm2/profile.json"

defaults export com.googlecode.iterm2 - | python3 - "$out" <<'PY'
import plistlib, json, sys

out_path = sys.argv[1]
prefs = plistlib.loads(sys.stdin.buffer.read())

profiles = prefs.get("New Bookmarks", [])
default_guid = prefs.get("Default Bookmark Guid")

profile = None
if default_guid:
    profile = next((p for p in profiles if p.get("Guid") == default_guid), None)
if profile is None and profiles:
    # Fall back to the profile literally named "Default", else the first one.
    profile = next((p for p in profiles if p.get("Name") == "Default"), profiles[0])
if profile is None:
    sys.exit("No iTerm2 profiles found in com.googlecode.iterm2 prefs.")

# Strip the keys that Nix injects / that shouldn't be inherited.
drop = {"Guid", "Name", "Custom Command", "Command",
        "Dynamic Profile Parent Name", "Dynamic Profile Parent GUID"}
clean = {k: v for k, v in profile.items() if k not in drop}

with open(out_path, "w") as f:
    json.dump(clean, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"Wrote {len(clean)} keys from profile "
      f"'{profile.get('Name', '?')}' -> {out_path}")
PY

echo "Done. Review with: git diff home/apps/iterm2/profile.json"
