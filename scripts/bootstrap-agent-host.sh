#!/usr/bin/env bash
#
# bootstrap-agent-host.sh - one-time, re-runnable setup of a Linux agent host
# managed by this flake (system-manager + standalone home-manager).
#
# Usage: bootstrap-agent-host.sh [--dry-run]
#   --dry-run  print what would change; change nothing
#
# The accounts come from this host's own config (hosts/linux/<hostname>.nix): it prompts only for the
# 1Password token files the host sets (d.apps.onepassword.tokenFiles) and lists logins only for its
# agent-host accounts (d.agentHost.accounts). A personal-only host is never asked for a work token.
#
# Every step checks before it acts, so a second run is a no-op.
#
set -euo pipefail

# Everything runs inside main(), called on the last line: under `curl | bash`
# bash reads the whole function before executing any of it, so a dropped
# connection can't run half a script and child processes can't swallow the
# rest of it from stdin.
main() {

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi

REPO_URL="git@github.com:nwlnexus/nix-darwin-hm.git"
REPO="$HOME/projects/personal/nix-darwin-hm"
HOST="$(hostname -s)"

# Evaluate an attribute of this host's home-manager config, passed through --apply FN, as raw text.
# Needs the checkout (step 3) and Nix (step 1); before the clone exists (a first --dry-run) it says so
# and prints nothing.
host_attr() {
  if [ ! -e "$REPO/.git" ]; then
    echo "  (no checkout yet: accounts are read from $REPO after step 3)" >&2
    return 0
  fi
  nix --extra-experimental-features 'nix-command flakes' eval --raw \
    "$REPO#homeConfigurations.\"$USER@$HOST\".config.$1" --apply "$2" || {
    echo "  could not evaluate $1 for $USER@$HOST: is hosts/linux/$HOST.nix in $REPO?" >&2
    exit 1
  }
}

say() { printf '\n==> %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then printf '  + %s\n' "$*"; else "$@"; fi
}

say "1/8 Nix (multi-user, nix-installer)"
if [ -d /nix ]; then
  echo "  already installed"
else
  run sh -c 'curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm'
fi
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

say "2/8 Remove native installs that home-manager now provides"
if [ -d "$HOME/.atuin/bin" ]; then run rm -rf "$HOME/.atuin/bin"; fi
if [ -d "$HOME/.config/atuin" ] && [ ! -L "$HOME/.config/atuin" ] && [ ! -e "$HOME/.config/atuin.pre-nix" ]; then
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

say "3/8 Flake checkout"
if [ ! -d "$REPO/.git" ]; then
  run git clone "$REPO_URL" "$REPO"
else
  echo "  $REPO present"
fi

say "4/8 1Password service-account tokens (the ones this host's config uses)"
# Assigned first (not `for x in $(...)`), so a failed evaluation stops the script under `set -e`.
# shellcheck disable=SC2016 # a Nix expression, not shell
token_files="$(host_attr d.apps.onepassword.tokenFiles 'f: builtins.concatStringsSep " " (builtins.attrValues (builtins.mapAttrs (n: v: "${n}=${v}") (builtins.removeAttrs f (builtins.filter (n: f.${n} == null) (builtins.attrNames f)))))')"
for entry in $token_files; do
  acct="${entry%%=*}"
  f="${entry#*=}"
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

say "5/8 Linuxbrew (formulae nixpkgs lacks; see home/linuxbrew.nix)"
if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  run env NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
else
  echo "  /home/linuxbrew/.linuxbrew present"
fi

say "6/8 Switch (system-manager, then home-manager)"
run "$REPO/scripts/linux-switch.sh"

say "7/8 GitHub token for private flake inputs"
if [ ! -s /etc/nix/github-token.conf ]; then
  env_file="$HOME/projects/personal/.env"
  pat=""
  if [ -f "$env_file" ]; then
    pat="$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' "$env_file" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
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

say "8/8 Manual follow-ups"
cat <<'EOF'
  For each agent-host account below: in ~/projects/<acct> run claude-<acct>, accept the trust
  prompt and /login (paste the code), then run codex-<acct> login --device-auth.
EOF
agent_accounts="$(host_attr d.agentHost.accounts 'a: builtins.concatStringsSep " " (builtins.attrNames a)')"
for acct in $agent_accounts; do
  echo "    $acct: cd ~/projects/$acct && claude-$acct ; codex-$acct login --device-auth"
done
cat <<'EOF'
  Then: agents restart && agents status
  If Tailscale shows "Logged out": sudo tailscale up
EOF
}

main "$@"
