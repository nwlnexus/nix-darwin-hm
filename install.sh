#!/usr/bin/env bash
# Bootstrap a fresh Mac: Homebrew, upstream Nix, then the first nix-darwin switch.
# Later switches use `just switch` (scripts/darwin-rebuild.sh).
# Linux agent hosts use scripts/bootstrap-agent-host.sh instead.
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}$*${NC}"; }
step() { echo -e "${YELLOW}$*${NC}"; }
ok() { echo -e "${GREEN}✓ $*${NC}"; }
die() {
  echo -e "${RED}Error: $*${NC}" >&2
  exit 1
}

# NIX_ROOT is overridable for tests only.
NIX_ROOT="${NIX_ROOT:-/nix}"
NIX_BIN="${NIX_ROOT}/var/nix/profiles/default/bin/nix"
NIX_DAEMON_SH="${NIX_ROOT}/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
LAUNCHD_DIR="${LAUNCHD_DIR:-/Library/LaunchDaemons}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

info "=== Nix and nix-darwin Setup ==="

case "$(uname -s)" in
  Darwin) ;;
  Linux)
    die "install.sh is for macOS. On a Linux agent host run scripts/bootstrap-agent-host.sh."
    ;;
  *) die "Unsupported operating system: $(uname -s)" ;;
esac

# --- Homebrew ---------------------------------------------------------------
load_brew() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

if command -v brew >/dev/null 2>&1; then
  ok "Homebrew is already installed"
else
  step "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew
  command -v brew >/dev/null 2>&1 || die "Homebrew installation failed. Check the output above."
  ok "Homebrew installed"
fi

# --- Nix (upstream, not Determinate) ----------------------------------------
# nix-darwin manages Nix itself and refuses to activate on Determinate Nix.
# Determinate Nix, not just the Determinate *installer*: an upstream install made with --prefer-upstream-nix
# also has a receipt that mentions Determinate and the installer's `systems.determinate.nix-installer.nix-hook`
# daemon (it restores Nix after macOS updates), so neither may count. What marks Determinate Nix is the receipt's
# `"determinate_nix": true` or its own daemon (`systems.determinate.nix-daemon`, `determinate-nixd`).
is_determinate() {
  if [ -f "${NIX_ROOT}/receipt.json" ] && grep -Eq '"determinate_nix"[[:space:]]*:[[:space:]]*true' "${NIX_ROOT}/receipt.json"; then
    return 0
  fi
  [ -e "${LAUNCHD_DIR}/systems.determinate.nix-daemon.plist" ] || [ -x /usr/local/bin/determinate-nixd ]
}

if is_determinate; then
  cat >&2 <<MSG
Determinate Nix is installed. nix-darwin cannot activate on it.
Uninstall it, then rerun this script (it installs upstream Nix):

  sudo ${NIX_ROOT}/nix-installer uninstall
  ./install.sh

This script does not uninstall anything for you.
MSG
  exit 1
fi

if [ -x "${NIX_BIN}" ]; then
  ok "Nix is already installed"
else
  step "Installing upstream Nix..."
  # Unattended runs (NONINTERACTIVE=1, as for the Homebrew installer, or no terminal) skip the installer's
  # confirmation prompt, which would otherwise abort with no TTY to answer it.
  nix_confirm=()
  if [ -n "${NONINTERACTIVE:-}" ] || [ ! -t 0 ]; then
    nix_confirm=(--no-confirm)
  fi
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --prefer-upstream-nix ${nix_confirm[@]+"${nix_confirm[@]}"}
  [ -x "${NIX_BIN}" ] || die "Nix installation failed: ${NIX_BIN} not found."
  ok "Nix installed"
fi

[ -e "${NIX_DAEMON_SH}" ] || die "Nix daemon profile not found: ${NIX_DAEMON_SH}"
# shellcheck disable=SC1090
. "${NIX_DAEMON_SH}"

# Enable flakes
step "Enabling Nix flakes..."
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >~/.config/nix/nix.conf
ok "Nix flakes enabled"

# --- Host name ----------------------------------------------------------------
# The flake picks the config by LocalHostName, so it must match a hosts/darwinM file.
host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
if [ ! -f "${SCRIPT_DIR}/hosts/darwinM/${host}.nix" ]; then
  available="$(cd "${SCRIPT_DIR}/hosts/darwinM" && printf '%s ' *.nix | sed 's|\.nix||g')"
  cat >&2 <<MSG
No host config for '${host}': hosts/darwinM/${host}.nix does not exist.
Available hosts: ${available}
Set the machine name to one of them (the name must match the file exactly), then rerun:

  sudo scutil --set ComputerName <host>
  sudo scutil --set HostName <host>
  sudo scutil --set LocalHostName <host>
MSG
  exit 1
fi
ok "Host config found for ${host}"

# --- First switch -------------------------------------------------------------
# Use the nix-darwin release this flake tracks.
darwin_ref="$(sed -n 's|.*darwin\.url = "github:nix-darwin/nix-darwin/\([^"]*\)".*|\1|p' "${SCRIPT_DIR}/flake.nix" | head -n1)"
[ -n "${darwin_ref}" ] || die "Could not read the nix-darwin release from flake.nix."

cd "${SCRIPT_DIR}"
# Build as the user first. A private flake input (olympus-sdk, read over ssh) can only be fetched with the
# user's ssh key; root has none, so a root-only first switch fails on it. Once built, the switch below finds
# everything in the store. Harmless on hosts without private inputs (the switch is then a cache hit).
step "Building the configuration for ${host} as ${USER} (fetches private inputs with your ssh key)..."
"${NIX_BIN}" build ".#darwinConfigurations.${host}.system" --no-link ||
  die "Failed to build the configuration for ${host}. Check the errors above (ssh access to private inputs?)."
ok "Configuration built"

step "Applying nix-darwin configuration for ${host} (nix-darwin ${darwin_ref}); sudo will ask for your password..."
sudo "${NIX_BIN}" run "nix-darwin/${darwin_ref}#darwin-rebuild" -- switch --flake ".#${host}" ||
  die "Failed to apply the nix-darwin configuration. Check the errors above."
ok "nix-darwin configuration applied"

echo
ok "Setup complete! Use 'just switch' for later changes."
