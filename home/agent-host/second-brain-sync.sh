# Keeps a checkout of the second-brain wiki on an agent host.
#   second-brain-sync clone   clone SECOND_BRAIN_REPO to SECOND_BRAIN_PATH when missing (activation; always exits 0)
#   second-brain-sync pull    fast-forward the checkout (timer; non-zero exit when it could not)
# Never deletes, resets, stashes or force-pulls: local work in the checkout is left as it is.
# Wrapped by writeShellApplication (set -euo pipefail; git and openssh on PATH).
: "${SECOND_BRAIN_PATH:?SECOND_BRAIN_PATH is not set}"
: "${SECOND_BRAIN_REPO:?SECOND_BRAIN_REPO is not set}"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new}"

log() { printf 'second-brain: %s\n' "$*" >&2; }
is_checkout() { git -C "$SECOND_BRAIN_PATH" rev-parse --git-dir >/dev/null 2>&1; }

do_clone() {
  if is_checkout; then
    return 0
  fi
  if [ -e "$SECOND_BRAIN_PATH" ] && [ -n "$(ls -A "$SECOND_BRAIN_PATH" 2>/dev/null || true)" ]; then
    log "$SECOND_BRAIN_PATH exists and is not a git checkout; leaving it alone"
    return 0
  fi
  mkdir -p "$(dirname "$SECOND_BRAIN_PATH")"
  # Clone beside the target and move it in, so a failed clone never leaves a half-made checkout.
  tmp="$(mktemp -d "$SECOND_BRAIN_PATH.clone.XXXXXX")"
  if git clone --quiet "$SECOND_BRAIN_REPO" "$tmp/repo"; then
    rmdir "$SECOND_BRAIN_PATH" 2>/dev/null || true
    mv "$tmp/repo" "$SECOND_BRAIN_PATH"
    log "cloned into $SECOND_BRAIN_PATH"
  else
    log "clone failed (no access yet?); will retry on the next switch or timer run"
  fi
  rm -rf "$tmp"
}

do_pull() {
  if ! is_checkout; then
    do_clone
    is_checkout || { log "no checkout at $SECOND_BRAIN_PATH"; return 1; }
    return 0
  fi
  before="$(git -C "$SECOND_BRAIN_PATH" rev-parse HEAD 2>/dev/null || echo none)"
  if git -C "$SECOND_BRAIN_PATH" pull --ff-only --quiet; then
    after="$(git -C "$SECOND_BRAIN_PATH" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then log "up to date at ${after:0:12}"; else log "fast-forwarded ${before:0:12} -> ${after:0:12}"; fi
  else
    log "pull --ff-only failed (diverged, dirty, or offline); nothing was changed"
    return 1
  fi
}

case "${1:-}" in
  clone) do_clone || true ;;
  pull) do_pull ;;
  *) echo "usage: second-brain-sync clone|pull" >&2; exit 2 ;;
esac
