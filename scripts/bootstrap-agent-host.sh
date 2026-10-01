#!/usr/bin/env bash
#
# bootstrap-agent-host.sh - one-time, re-runnable setup of a Linux agent host
# managed by this flake (system-manager + standalone home-manager).
#
# Usage: bootstrap-agent-host.sh [--dry-run]
#   --dry-run  print what would change; change nothing
#
# Every step checks before it acts, so a second run is a no-op.
#
set -euo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi

REPO_URL="git@github.com:nwlnexus/nix-darwin-hm.git"
REPO="$HOME/projects/personal/nix-darwin-hm"

say() { printf '\n==> %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then printf '  + %s\n' "$*"; else "$@"; fi
}

say "1/7 Nix (multi-user, nix-installer)"
if [ -d /nix ]; then
  echo "  already installed"
else
  run sh -c 'curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm'
fi
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

say "2/7 1Password service-account tokens"
for acct in personal work; do
  f="$HOME/.config/$acct/1penv"
  if [ -s "$f" ]; then
    echo "  $f present"
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "  + prompt for the $acct token -> $f"
    continue
  fi
  read -rsp "  $acct service-account token: " tok </dev/tty
  echo
  if [ -z "$tok" ]; then
    echo "  empty token; aborting" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")"
  (umask 077 && printf '%s' "$tok" >"$f")
  unset tok
done

say "3/7 Remove native installs that home-manager now provides"
if [ -d "$HOME/.atuin/bin" ]; then run rm -rf "$HOME/.atuin/bin"; fi
if [ -d "$HOME/.config/atuin" ] && [ ! -L "$HOME/.config/atuin" ]; then
  run mv "$HOME/.config/atuin" "$HOME/.config/atuin.pre-nix"
fi
if [ -e /usr/local/bin/starship ]; then run sudo rm -f /usr/local/bin/starship; fi
for b in zoxide mise; do
  if [ -e "$HOME/.local/bin/$b" ]; then run rm -f "$HOME/.local/bin/$b"; fi
done
if dpkg -s direnv >/dev/null 2>&1; then run sudo apt-get remove -y direnv; fi
# bash isn't managed by home-manager here; drop hooks for removed binaries.
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -qE 'atuin|starship|zoxide' "$rc"; then
    run sed -i.pre-nix -E '/atuin|starship|zoxide/d' "$rc"
  fi
done
echo "  kept: ~/.local/share/atuin (history), claude, codex, rustup, apt op"

say "4/7 Flake checkout"
if [ ! -d "$REPO/.git" ]; then
  run git clone "$REPO_URL" "$REPO"
else
  echo "  $REPO present"
fi

say "5/7 Switch (system-manager, then home-manager)"
run "$REPO/scripts/linux-switch.sh"

say "6/7 GitHub token for private flake inputs"
if [ ! -s /etc/nix/github-token.conf ]; then
  env_file="$HOME/projects/personal/.env"
  pat=""
  if [ -f "$env_file" ]; then
    pat="$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' "$env_file" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
  fi
  if [ -n "$pat" ]; then
    if [ "$DRY" = 1 ]; then
      echo "  + write /etc/nix/github-token.conf (root:root 0600)"
    else
      printf 'access-tokens = github.com=%s\n' "$pat" | sudo tee /etc/nix/github-token.conf >/dev/null
      sudo chmod 600 /etc/nix/github-token.conf
      sudo chown root:root /etc/nix/github-token.conf
    fi
  else
    echo "  no GITHUB_PERSONAL_ACCESS_TOKEN in $env_file yet; re-run after secrets materialize"
  fi
  unset pat
else
  echo "  /etc/nix/github-token.conf present"
fi

say "7/7 Manual follow-ups"
cat <<'EOF'
  For each account (personal, work):
    cd ~/projects/<acct> && claude-<acct>          # accept trust prompt, then /login (paste code)
    codex-<acct> login --device-auth
  Then:
    agents restart && agents status
  If Tailscale shows "Logged out":
    sudo tailscale up
EOF
