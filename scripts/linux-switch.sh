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

echo "==> system-manager switch ($HOST)"
nix run "$REPO#system-manager" -- switch --flake "$REPO#$HOST" --sudo

echo "==> sshd: validate drop-ins, then reload"
if sudo sshd -t; then
  sudo systemctl reload ssh
else
  echo "sshd rejected its config; NOT reloading (current daemon keeps running)" >&2
  exit 1
fi

echo "==> home-manager switch ($USER@$HOST)"
nix run "$REPO#home-manager" -- switch -b backup --flake "$REPO#$USER@$HOST"
