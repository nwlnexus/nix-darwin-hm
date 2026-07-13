default:
    @just --list

fmt:
    treefmt

# Capture this host's live iTerm2 default profile into the repo template
# (home/apps/iterm2/profile.json). Quit iTerm2 first so prefs are flushed.
export-iterm-profile:
    ./scripts/export-iterm-profile.sh

# Manual SSH key fetch — normally op-secrets (via home-manager activation)
# handles this declaratively. Use these recipes only as an escape hatch
# (e.g. fresh machine, op-secrets failed, or you want a quick re-fetch
# without rebuilding).
fetch-ssh-keys: fetch-work-ssh-key fetch-personal-ssh-key

fetch-work-ssh-key:
    op --account="dtlrinc.1password.com" read "op://Employee/3hef3bpdxdt4bdl5ptkm5d3jou/private key" > ~/.ssh/gitlab-work-gl && chmod 600 ~/.ssh/gitlab-work-gl && echo "GitLab SSH key placed at ~/.ssh/gitlab-work-gl"

# Uses the service-account token in ~/projects/personal/.env — fully
# non-interactive, no 1Password desktop app required.
fetch-personal-ssh-key:
    #!/usr/bin/env bash
    set -euo pipefail
    token="$(grep -E '^OP_SERVICE_ACCOUNT_TOKEN=' ~/projects/personal/.env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    OP_SERVICE_ACCOUNT_TOKEN="$token" op read "op://Private/obvqbmo4u6fxdhrrmb6jq2li5e/private key" > ~/.ssh/id_ed25519_personal
    chmod 600 ~/.ssh/id_ed25519_personal
    OP_SERVICE_ACCOUNT_TOKEN="$token" op read "op://Private/obvqbmo4u6fxdhrrmb6jq2li5e/public key" > ~/.ssh/id_ed25519_personal.pub
    chmod 644 ~/.ssh/id_ed25519_personal.pub
    echo "Personal SSH key placed at ~/.ssh/id_ed25519_personal"

# Materialize the GitHub access token for nix's github: fetcher so ROOT evals
# (sudo darwin-rebuild switch) can fetch private flake inputs like
# github:nwlnexus/mnemosyne. Reads the op-provisioned PAT from
# ~/projects/personal/.env; system/nix.nix `!include`s the resulting file.
# Run once per host (and re-run if the PAT rotates). Requires sudo.
materialize-nix-github-token:
    #!/usr/bin/env bash
    set -euo pipefail
    pat="$(/usr/bin/grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' ~/projects/personal/.env | /usr/bin/head -n1 | /usr/bin/cut -d= -f2- | tr -d '"' | tr -d "'")"
    [ -n "$pat" ] || { echo "no GITHUB_PERSONAL_ACCESS_TOKEN in ~/projects/personal/.env (rebuild home-manager first)"; exit 1; }
    printf 'access-tokens = github.com=%s\n' "$pat" | sudo tee /etc/nix/github-token.conf >/dev/null
    sudo chmod 600 /etc/nix/github-token.conf && sudo chown root:wheel /etc/nix/github-token.conf
    echo "Wrote /etc/nix/github-token.conf (root:wheel 0600)"
    echo
    echo "BOOTSTRAP NOTE: the !include of this file only lands in /etc/nix/nix.conf"
    echo "after a successful switch, so the FIRST rebuild on this host needs the"
    echo "token passed explicitly:"
    echo
    echo '  sudo NIX_CONFIG="$(sudo cat /etc/nix/github-token.conf)" darwin-rebuild switch --flake .'
    echo
    echo "Subsequent rebuilds need no prefix."

# Bump the locked mnemosyne flake input (private repo — needs github-token.conf).
# Run `just materialize-nix-github-token` first if you haven't on this host.
update-mnemosyne-flake:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f /etc/nix/github-token.conf ]; then
      echo "missing /etc/nix/github-token.conf — run: just materialize-nix-github-token" >&2
      exit 1
    fi
    nix_conf="$(sudo cat /etc/nix/github-token.conf)"
    NIX_CONFIG="$nix_conf" nix flake update mnemosyne
    echo "Updated flake.lock — commit if intentional, then darwin-rebuild."

# First darwin-rebuild after materialize-nix-github-token (before !include is live).
darwin-rebuild-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f /etc/nix/github-token.conf ]; then
      echo "missing /etc/nix/github-token.conf — run: just materialize-nix-github-token" >&2
      exit 1
    fi
    sudo NIX_CONFIG="$(sudo cat /etc/nix/github-token.conf)" darwin-rebuild switch --flake .

# Materialize the nwlnexus R2 nix binary-cache substituter + credentials so
# the nix daemon substitutes mnemosyne's CI-built closure instead of building
# it locally. Same pattern as materialize-nix-github-token: system/nix.nix
# `!include`s /etc/nix/r2-cache.conf, so hosts that never run this recipe are
# unaffected. Reads from 1Password (adjust the op:// refs below if the item
# fields are named differently). Run once per host; re-run on key rotation.
materialize-r2-cache-creds:
    #!/usr/bin/env bash
    set -euo pipefail
    read_ref() { op read "$1" 2>/dev/null || { echo "op read failed for $1 — fix the op:// ref in this recipe to match your vault item fields" >&2; exit 1; }; }
    account_id="$(read_ref "op://Dev/cloudflare-account-id/account-id")"
    key_id="$(read_ref "op://Dev/cloudflare-r2-access/access-key-id")"
    secret="$(read_ref "op://Dev/cloudflare-r2-access/secret-access-key")"
    printf 'extra-substituters = s3://nwlnexus-nix-cache?endpoint=https://%s.r2.cloudflarestorage.com&region=auto&profile=nwlnexus-r2\n' "$account_id" \
      | sudo tee /etc/nix/r2-cache.conf >/dev/null
    sudo chmod 600 /etc/nix/r2-cache.conf && sudo chown root:wheel /etc/nix/r2-cache.conf
    # nix's S3 substituter resolves credentials via the AWS SDK chain of the
    # daemon (root). A dedicated profile keeps any root default profile intact.
    sudo mkdir -p /var/root/.aws
    if sudo grep -q '^\[nwlnexus-r2\]' /var/root/.aws/credentials 2>/dev/null; then
      echo "profile [nwlnexus-r2] already present in /var/root/.aws/credentials — update it manually if rotating" >&2
    else
      printf '[nwlnexus-r2]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$key_id" "$secret" \
        | sudo tee -a /var/root/.aws/credentials >/dev/null
    fi
    sudo chmod 600 /var/root/.aws/credentials && sudo chown root:wheel /var/root/.aws/credentials
    echo "Wrote /etc/nix/r2-cache.conf and root AWS profile [nwlnexus-r2]."
    echo "The !include lands in /etc/nix/nix.conf on the next darwin-rebuild switch."
