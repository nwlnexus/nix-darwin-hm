# Nightly knowledge compile (olympus-sdk #455): gateway facts and raw/_inbox proposals -> second-brain wiki articles,
# accepted by the claim-verifier and merged by the automerge label. Wrapped by writeShellApplication (set -euo pipefail).
#   memory-compile-run [compile.mjs run args...]
# Works in its own clone (MEMORY_COMPILE_DIR), never in the /brain checkout the hourly pull keeps. The compile code is
# second-brain's own scripts/compile/compile.mjs at origin/main, so a merged change there is picked up without nix.
# MEMORY_ENV_FILE: the olympus-memory env file (gateway URL and key file; no secrets in it). CLAUDE_CONFIG_DIR: the
# personal account (drafting and the claim-verifier agent run as it).
: "${MEMORY_COMPILE_DIR:?MEMORY_COMPILE_DIR is not set}"
: "${SECOND_BRAIN_REPO:?SECOND_BRAIN_REPO is not set}"
: "${MEMORY_ENV_FILE:?MEMORY_ENV_FILE is not set}"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new}"
# claude is the native install in ~/.local/bin (it self-updates); nix does not wrap it.
export PATH="$HOME/.local/bin:$PATH"

log() { printf 'memory-compile-run: %s\n' "$*" >&2; }

if [ ! -r "$MEMORY_ENV_FILE" ]; then
  log "no $MEMORY_ENV_FILE (olympus-memory not set up for this account); skipping"
  exit 0
fi
# shellcheck disable=SC1090
. "$MEMORY_ENV_FILE"
export MEMORY_GATEWAY_URL MEMORY_KEY_FILE

# gh (the compile opens its PR with it) authenticates from GH_TOKEN, as in the claude-<acct> launchers.
if [ -z "${GH_TOKEN:-}" ] && [ -n "${MEMORY_COMPILE_SECRETS_FILE:-}" ] && [ -r "$MEMORY_COMPILE_SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  GITHUB_PERSONAL_ACCESS_TOKEN="$(set -a; . "$MEMORY_COMPILE_SECRETS_FILE" >/dev/null 2>&1; printf '%s' "${GITHUB_PERSONAL_ACCESS_TOKEN:-}")"
  if [ -n "$GITHUB_PERSONAL_ACCESS_TOKEN" ]; then export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"; fi
  unset GITHUB_PERSONAL_ACCESS_TOKEN
fi

if ! git -C "$MEMORY_COMPILE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  mkdir -p "$(dirname "$MEMORY_COMPILE_DIR")"
  git clone --quiet "$SECOND_BRAIN_REPO" "$MEMORY_COMPILE_DIR"
fi
git -C "$MEMORY_COMPILE_DIR" fetch --quiet origin
git -C "$MEMORY_COMPILE_DIR" checkout --quiet -B main origin/main
git -C "$MEMORY_COMPILE_DIR" clean -fdq
if [ ! -f "$MEMORY_COMPILE_DIR/scripts/compile/compile.mjs" ]; then
  log "second-brain has no scripts/compile/compile.mjs yet; skipping"
  exit 0
fi
exec node "$MEMORY_COMPILE_DIR/scripts/compile/compile.mjs" run --dir "$MEMORY_COMPILE_DIR" "$@"
