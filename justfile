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
    pat="$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' ~/projects/personal/.env | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    [ -n "$pat" ] || { echo "no GITHUB_PERSONAL_ACCESS_TOKEN in ~/projects/personal/.env (rebuild home-manager first)"; exit 1; }
    printf 'access-tokens = github.com=%s\n' "$pat" | sudo tee /etc/nix/github-token.conf >/dev/null
    sudo chmod 600 /etc/nix/github-token.conf && sudo chown root:wheel /etc/nix/github-token.conf
    echo "Wrote /etc/nix/github-token.conf (root:wheel 0600)"
