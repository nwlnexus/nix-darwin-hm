#!/usr/bin/env bash
#
# linux-switch.sh - apply this Linux host's system-manager and home-manager
# configs from the flake. Host = short hostname (hosts/linux/<host>.nix).
#
# The CLIs come from this flake's packages, so their versions follow flake.lock.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$(hostname -s)"

# Non-interactive shells (e.g. `ssh host cmd`) don't get the installer's
# PATH hooks (/etc/zsh/zshrc, /etc/profile.d), so load Nix if it's missing.
if ! command -v nix >/dev/null 2>&1 && [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# The upstream nix-installer leaves flakes off, and the first switch runs
# before system-manager writes nix.conf. NIX_CONFIG also reaches the nix
# calls that system-manager and home-manager make internally.
export NIX_CONFIG="extra-experimental-features = nix-command flakes"

echo "==> system-manager switch ($HOST)"
nix run "$REPO#system-manager" -- switch --flake "$REPO#$HOST" --sudo

echo "==> sshd: validate drop-ins, then reload"
# Ubuntu socket-activates sshd, so /run/sshd may not exist; `sshd -t` needs it.
sudo install -d -m 0755 /run/sshd
if sudo sshd -t; then
  # No-op when ssh.service is inactive: socket-activated sshd reads the new
  # drop-in on the next connection.
  sudo systemctl try-reload-or-restart ssh
else
  echo "sshd rejected its config; NOT reloading (current daemon keeps running)" >&2
  exit 1
fi

echo "==> home-manager switch ($USER@$HOST)"
nix run "$REPO#home-manager" -- switch -b backup --flake "$REPO#$USER@$HOST"
