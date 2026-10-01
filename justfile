default:
    @just --list

# `treefmt` is not installed on PATH — it only exists as this flake's
# formatter wrapper (flake.nix `outputsBuilder.formatter`), so go through
# `nix fmt` rather than expecting a bare binary.
# Format the tree (nixfmt via treefmt-nix).
fmt:
    nix fmt

# Works on every machine regardless of whether the repo sits on the boot
# volume (laptop) or on an external drive mounted `noowners` (the desktops,
# where ~/projects symlinks to /Volumes/<drive>/projects). See
# scripts/darwin-rebuild.sh for why a bare `sudo darwin-rebuild switch` fails
# on the external-drive hosts.
# Rebuild and activate this host. Override the host: `just switch NWL-MBM2`.
switch host="":
    ./scripts/darwin-rebuild.sh switch {{ host }}

# Uses the same flake reference as `just switch`, so it genuinely warms the
# cache for the subsequent switch (the git and path fetchers hash differently).
# Build this host's system closure without activating it, and without sudo.
build host="":
    ./scripts/darwin-rebuild.sh build {{ host }}

# Dry-run: build this host and report what would change (needs sudo).
check host="":
    ./scripts/darwin-rebuild.sh check {{ host }}

# Let ROOT's git open this repo, so `sudo darwin-rebuild switch --flake .`
# works directly and Nix can use its leaner git fetcher instead of the
# `path:` workaround (which copies the whole worktree into the store).
#
# Only needed on hosts where this repo lives on an external drive — macOS
# mounts those `noowners`, and libgit2 then refuses to open the repo as root.
#
# The `-H` is load-bearing: macOS sudo preserves $HOME by default, so without
# it this would write to YOUR git config, which a root rebuild never reads
# (darwin-rebuild resets HOME=~root when euid is 0).
#
# Unverified on these hosts — if a plain `sudo darwin-rebuild switch` still
# fails afterwards, `just switch` keeps working regardless.
# Register this repo as a safe.directory for ROOT's git (external-drive hosts).
git-safe-directory:
    #!/usr/bin/env bash
    set -euo pipefail
    repo="$(pwd -P)"
    if sudo -H git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$repo"; then
      echo "already registered for root: $repo"
      exit 0
    fi
    sudo -H git config --global --add safe.directory "$repo"
    echo "Registered as a safe.directory for root: $repo"
    echo "Written to /var/root/.gitconfig — re-run per host, and after moving the repo."

# Undo git-safe-directory on this host.
git-safe-directory-remove:
    #!/usr/bin/env bash
    set -euo pipefail
    repo="$(pwd -P)"
    sudo -H git config --global --unset-all safe.directory "$(printf '%s' "$repo" | sed 's/[].[^$\\*]/\\&/g')" || true
    echo "Removed root safe.directory entry for: $repo"

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
# (sudo darwin-rebuild switch) can fetch private flake inputs. Reads the op-provisioned PAT from
# ~/projects/personal/.env; system/nix.nix `!include`s the resulting file.
# Run once per host (and re-run if the PAT rotates). Requires sudo.
materialize-nix-github-token:
    #!/usr/bin/env bash
    set -euo pipefail
    pat="$(/usr/bin/grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' ~/projects/personal/.env | /usr/bin/head -n1 | /usr/bin/cut -d= -f2- | tr -d '"' | tr -d "'")"
    [ -n "$pat" ] || { echo "no GITHUB_PERSONAL_ACCESS_TOKEN in ~/projects/personal/.env (rebuild home-manager first)"; exit 1; }
    printf 'access-tokens = github.com=%s\n' "$pat" | sudo tee /etc/nix/github-token.conf >/dev/null
    sudo chmod 600 /etc/nix/github-token.conf && sudo chown "root:$(id -gn root)" /etc/nix/github-token.conf
    echo "Wrote /etc/nix/github-token.conf (root:wheel 0600)"
    echo
    echo "BOOTSTRAP NOTE: the !include of this file only lands in /etc/nix/nix.conf"
    echo "after a successful switch, so the FIRST rebuild on this host needs the"
    echo "token passed explicitly:"
    echo
    echo '  sudo NIX_CONFIG="$(sudo cat /etc/nix/github-token.conf)" darwin-rebuild switch --flake .'
    echo
    echo "Subsequent rebuilds need no prefix."

# Goes through scripts/darwin-rebuild.sh so it works on the external-drive
# hosts too — a bare `--flake .` fails there under sudo.
# First darwin-rebuild after materialize-nix-github-token (before !include is live).
darwin-rebuild-bootstrap host="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f /etc/nix/github-token.conf ]; then
      echo "missing /etc/nix/github-token.conf — run: just materialize-nix-github-token" >&2
      exit 1
    fi
    DARWIN_REBUILD_NIX_CONFIG="$(sudo cat /etc/nix/github-token.conf)" \
      ./scripts/darwin-rebuild.sh switch {{ host }}

# Run the Nix evaluation tests in tests/ (prints failures; [] = all pass)
test:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(nix eval --impure --json --expr 'import ./tests { }')"
    echo "$out" | jq .
    [ "$out" = "[]" ]

# Print a normalized snapshot of a darwin host's evaluated config.
# With a ref, evaluates that git revision of this repo instead of the working tree.
darwin-snapshot host="NWL-MMINI" ref="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{ ref }}" ]; then
      # The main checkout (not a linked worktree) shares the object store.
      main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
      src="git+file://$main?rev=$(git rev-parse {{ ref }})"
    else
      src="$(pwd)"
    fi
    nix eval --impure --json --expr \
      "import ./tests/lib/darwin-snapshot.nix { flake = builtins.getFlake \"$src\"; host = \"{{ host }}\"; }" \
      | jq -S .

# Fail (and show the diff) if a darwin host's config differs from ref
check-darwin host="NWL-MMINI" ref="origin/main":
    #!/usr/bin/env bash
    set -euo pipefail
    diff -u <(just darwin-snapshot {{ host }} {{ ref }}) <(just darwin-snapshot {{ host }}) \
      && echo "darwin {{ host }}: unchanged vs {{ ref }}"
