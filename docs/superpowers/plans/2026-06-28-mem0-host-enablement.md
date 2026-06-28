# mem0 Host Enablement + claude-mem Decommission — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, idempotent home-manager module that decommissions claude-mem (full local teardown), migrates its DB to mem0, and enables the mem0 recall hook both declaratively via nix and ad-hoc via one `mem0ctl` script.

**Architecture:** A new `home/cli/claude/` module in nix-darwin-hm owns a unified `mem0ctl` bash script (subcommand-dispatched), a compact SessionStart recall hook with an extracted Python formatter, and the Python migration tool moved verbatim out of olympus-sdk. Nix installs `mem0ctl` (deps bundled via `makeWrapper`) and the hook to `~/.claude/`, and runs `mem0ctl enable --no-verify` on every `darwin-rebuild`. `settings.json` is merged imperatively with jq (it is also written by Claude Code); the hook file is declarative. A second PR removes the tool + refs from olympus-sdk once the new copy is proven.

**Tech Stack:** Nix / home-manager (darwin), bash + jq + curl, Python 3 (formatter + migrate tool, run via `uv`), pytest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-28-mem0-host-enablement-design.md` (verbatim authority).
- All `mem0ctl` subcommands MUST be **idempotent** and **fail-soft**: the activation path calls them with `|| true`; non-zero exit only on explicit ad-hoc misuse.
- The recall hook MUST keep its **fail-open** contract: any error → print `{"continue":true}` and exit 0.
- `settings.json` / `~/.claude.json` / `installed_plugins.json` writes are **atomic** (temp + `mv`) and MUST NOT rewrite unrelated keys. Back up `~/.claude.json` before mangling.
- **Keep** `~/.claude-mem/*.premem0-*` and `mem0-migrate-checkpoint.json`. **Delete** the live working set (`claude-mem.db*`, `chroma/`, `vector-db/`) only when a `*.premem0-*` backup is confirmed present.
- Defaults baked in: `MEM0_URL=http://openmemory.raptor-mimosa.ts.net:8765`, `MEM0_USER_ID=mnemosyne`, `MEM0_TOP_K=3`.
- Paths used by `mem0ctl` MUST be overridable via env (`CLAUDE_DIR`, `CLAUDE_MEM_DIR`, `CLAUDE_JSON`) so shell tests run in an isolated temp `$HOME`.
- Tests are required and MUST pass before each commit (project rule).
- olympus-sdk deletion (Task 9) happens **only after** Task 8 proves the new copy end-to-end.
- Commit per task. Conventional commits. End commit messages with the Co-Authored-By trailer the repo uses.

## File Structure

```
home/cli/claude/
  default.nix              # NEW — nix module: mem0ctl pkg, home.file (hook+formatter), home.activation
  mem0ctl.sh               # NEW — unified script (disable-claude-mem | migrate | enable | bootstrap)
  mem0-recall-hook.sh      # NEW — thin SessionStart wrapper, fail-open
  mem0_recall_format.py    # NEW — importable, unit-testable formatter
  mem0-migrate/            # MOVED verbatim from olympus-sdk tools/mem0-migrate/
  tests/
    test_recall_format.py  # NEW — formatter unit tests
    test_mem0ctl.sh        # NEW — POSIX shell tests (isolated temp HOME)
home/cli/default.nix       # MODIFY — add ./claude to imports
```

olympus-sdk (Task 9, separate PR): delete `tools/mem0-migrate/`; scrub live-tool refs.

---

### Task 1: Move the Python migration tool into nix-darwin-hm

**Files:**
- Create: `home/cli/claude/mem0-migrate/` (verbatim copy of olympus-sdk `tools/mem0-migrate/`)

**Interfaces:**
- Produces: console script `mem0-migrate` (`mem0_migrate.run:main`), CLI flags `--db --url --user-id --mode {smoke,full} --checkpoint --concurrency --limit --app`. Runtime dep `httpx` is supplied at call time via `uv run --with httpx` (not a project dependency).

- [ ] **Step 1: Copy the tool verbatim**

```bash
mkdir -p home/cli/claude
cp -R ~/projects/personal/olympus-sdk/tools/mem0-migrate home/cli/claude/mem0-migrate
# Drop any local run artifacts that should not be vendored.
rm -f home/cli/claude/mem0-migrate/.mem0-migrate-checkpoint.json
```

- [ ] **Step 2: Verify the suite passes in its new location**

Run: `cd home/cli/claude/mem0-migrate && uv run --with httpx pytest -q`
Expected: all tests PASS (same suite that passed in olympus-sdk: `test_db`, `test_compose`, `test_checkpoint`, `test_run`).

- [ ] **Step 3: Confirm no olympus-sdk coupling remains**

Run: `grep -rn "olympus" home/cli/claude/mem0-migrate || echo "no olympus refs"`
Expected: `no olympus refs` (or only incidental mentions in README prose — if README references the olympus path/epic, leave the epic mention, drop any hard path dependency).

- [ ] **Step 4: Commit**

```bash
git add home/cli/claude/mem0-migrate
git commit -m "feat(claude): vendor mem0-migrate tool from olympus-sdk"
```

---

### Task 2: Recall formatter (`mem0_recall_format.py`)

**Files:**
- Create: `home/cli/claude/mem0_recall_format.py`
- Test: `home/cli/claude/tests/test_recall_format.py`

**Interfaces:**
- Produces: `format_block(data: dict, cwd: str, top_k: int = 3, width: int = 200) -> str | None` and a `__main__` that reads API JSON on stdin, takes `cwd` as `argv[1]`, and prints either the SessionStart `hookSpecificOutput` JSON or `{"continue": true}`.

- [ ] **Step 1: Write the failing tests**

```python
# home/cli/claude/tests/test_recall_format.py
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mem0_recall_format as f


def test_header_and_count():
    data = {"total": 12, "items": [{"memory": "alpha"}, {"memory": "beta"},
                                   {"memory": "gamma"}, {"memory": "delta"}]}
    block = f.format_block(data, "/Users/x/projects/olympus-sdk", top_k=3)
    assert block is not None
    lines = block.splitlines()
    assert lines[0] == "Recalled 12 memories for olympus-sdk — top 3:"
    assert len(lines) == 4          # header + 3 items (top_k caps at 3)
    assert lines[1].startswith("1. ")


def test_truncation():
    block = f.format_block({"total": 1, "items": [{"memory": "x" * 500}]},
                           "/tmp/proj", width=200)
    item_line = block.splitlines()[1]
    assert len(item_line) <= 3 + 200        # "1. " prefix + width
    assert item_line.endswith("…")


def test_empty_response_returns_none():
    assert f.format_block({"total": 0, "items": []}, "/tmp/proj") is None


def test_main_fail_open_on_bad_json():
    proc = subprocess.run([sys.executable, str(Path(f.__file__)), "/tmp/proj"],
                          input="not json", capture_output=True, text=True)
    assert json.loads(proc.stdout) == {"continue": True}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd home/cli/claude && uv run pytest tests/test_recall_format.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'mem0_recall_format'`.

- [ ] **Step 3: Implement the formatter**

```python
# home/cli/claude/mem0_recall_format.py
"""Format OpenMemory /filter responses into a compact SessionStart block.

Pure + importable so formatting is unit-testable. The bash hook pipes raw API
JSON to __main__, which prints the SessionStart hookSpecificOutput JSON, or
{"continue": true} on any empty/error path (fail-open).
"""
from __future__ import annotations

import json
import os
import sys

TOP_K = int(os.environ.get("MEM0_TOP_K", "3"))
WIDTH = int(os.environ.get("MEM0_LINE_WIDTH", "200"))


def _truncate(text: str, width: int) -> str:
    one_line = " ".join(text.split())
    if len(one_line) <= width:
        return one_line
    return one_line[: width - 1].rstrip() + "…"


def format_block(data: dict, cwd: str, top_k: int = TOP_K, width: int = WIDTH):
    """Return a compact markdown block, or None when there is nothing to show."""
    items = data.get("items") or []
    total = data.get("total", len(items)) or 0
    if not items or total == 0:
        return None
    project = os.path.basename(cwd.rstrip("/")) or cwd or "this project"
    shown = min(top_k, len(items))
    lines = [f"Recalled {total} memories for {project} — top {shown}:"]
    for i, item in enumerate(items[:top_k], 1):
        memory = (item.get("memory") or item.get("text") or "").strip()
        if memory:
            lines.append(f"{i}. {_truncate(memory, width)}")
    return "\n".join(lines) if len(lines) > 1 else None


def main(argv):
    cwd = argv[1] if len(argv) > 1 else os.getcwd()
    try:
        data = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"continue": True}))
        return 0
    block = format_block(data, cwd)
    if not block:
        print(json.dumps({"continue": True}))
        return 0
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": block,
        }
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd home/cli/claude && uv run pytest tests/test_recall_format.py -q`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add home/cli/claude/mem0_recall_format.py home/cli/claude/tests/test_recall_format.py
git commit -m "feat(claude): compact, unit-testable mem0 recall formatter"
```

---

### Task 3: Recall hook wrapper (`mem0-recall-hook.sh`)

**Files:**
- Create: `home/cli/claude/mem0-recall-hook.sh`

**Interfaces:**
- Consumes: `mem0_recall_format.py` (resolved as a sibling — works whether the hook is a nix-store symlink or an ad-hoc copy).
- Produces: SessionStart hook output on stdout (JSON), fail-open on every error.

- [ ] **Step 1: Write the hook**

```bash
#!/usr/bin/env bash
# mem0-recall-hook.sh — SessionStart auto-recall for OpenMemory/Mem0 (fail-open).
# Resolves its sibling formatter whether installed as a nix-store symlink or
# copied into ~/.claude/hooks, then prints the SessionStart additionalContext
# JSON (or {"continue":true} on any error).
set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
MEM0_TOP_K="${MEM0_TOP_K:-3}"

fail_open() { printf '{"continue":true}\n'; exit 0; }

command -v python3 >/dev/null 2>&1 || fail_open
command -v curl    >/dev/null 2>&1 || fail_open

# Resolve the directory holding the formatter sibling.
src="${BASH_SOURCE[0]}"
hook_dir="$(cd "$(dirname "$src")" && pwd -P)"
if [ ! -f "$hook_dir/mem0_recall_format.py" ]; then
  resolved="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src" 2>/dev/null || true)"
  [ -n "$resolved" ] && hook_dir="$(cd "$(dirname "$resolved")" && pwd -P)"
fi
formatter="$hook_dir/mem0_recall_format.py"
[ -f "$formatter" ] || fail_open

# Read the hook stdin JSON and extract cwd (fall back to PWD).
stdin_data=""
if read -r -t 2 line 2>/dev/null; then stdin_data="$line"; fi
cwd="$(printf '%s' "$stdin_data" | python3 -c 'import sys,json
try:
    print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception:
    print("")' 2>/dev/null || true)"
cwd="${cwd:-${PWD:-}}"
[ -n "$cwd" ] || fail_open

body="$(python3 -c 'import json,sys
print(json.dumps({"user_id":sys.argv[1],"search_query":sys.argv[2],"page":1,"size":int(sys.argv[3])}))' \
  "$MEM0_USER_ID" "$cwd" "$MEM0_TOP_K" 2>/dev/null)" || fail_open

resp="$(curl -fsS --connect-timeout 1 --max-time 2 \
  -X POST -H 'Content-Type: application/json' -d "$body" \
  "$MEM0_URL/api/v1/memories/filter" 2>/dev/null)" || fail_open

printf '%s' "$resp" | MEM0_TOP_K="$MEM0_TOP_K" python3 "$formatter" "$cwd" 2>/dev/null || fail_open
```

- [ ] **Step 2: Lint + smoke-test fail-open**

Run:
```bash
chmod +x home/cli/claude/mem0-recall-hook.sh
shellcheck home/cli/claude/mem0-recall-hook.sh
# Sibling formatter present + unreachable URL => must fail open cleanly:
ln -sf "$PWD/home/cli/claude/mem0_recall_format.py" home/cli/claude/mem0_recall_format.py 2>/dev/null || true
echo '{"cwd":"/tmp/proj"}' | MEM0_URL="http://127.0.0.1:1" home/cli/claude/mem0-recall-hook.sh
```
Expected: shellcheck clean; output is exactly `{"continue":true}`.

- [ ] **Step 3: Commit**

```bash
git add home/cli/claude/mem0-recall-hook.sh
git commit -m "feat(claude): fail-open mem0 SessionStart recall hook"
```

---

### Task 4: `mem0ctl` — script skeleton + `disable-claude-mem`

**Files:**
- Create: `home/cli/claude/mem0ctl.sh`
- Test: `home/cli/claude/tests/test_mem0ctl.sh`

**Interfaces:**
- Produces: `mem0ctl disable-claude-mem` — kills claude-mem procs, disables across 3 layers, removes plugin cache, deletes live working set (keeps backup), idempotent. Env overrides `CLAUDE_DIR`, `CLAUDE_MEM_DIR`, `CLAUDE_JSON`.

- [ ] **Step 1: Write the failing shell test (disable cases)**

```bash
#!/usr/bin/env bash
# Shell tests for mem0ctl — isolated temp HOME, jq + bash only.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM0CTL="$SELF/../mem0ctl.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

setup() {
  TMP="$(mktemp -d)"
  export CLAUDE_DIR="$TMP/.claude" CLAUDE_MEM_DIR="$TMP/.claude-mem" CLAUDE_JSON="$TMP/.claude.json"
  mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/plugins/cache/thedotmack/claude-mem/13.8.1" "$CLAUDE_MEM_DIR/chroma"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/existing/other-hook.sh"}]}]}}' > "$CLAUDE_DIR/settings.json"
  printf '{"enabledPlugins":{"claude-mem@thedotmack":true,"keep@me":true},"mcpServers":{"claude-mem":{"x":1},"other":{"y":2}}}' > "$CLAUDE_JSON"
  printf '{}' > "$CLAUDE_DIR/plugins/installed_plugins.json"
  : > "$CLAUDE_MEM_DIR/claude-mem.db"
  : > "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627"
}
teardown() { rm -rf "$TMP"; }

# --- disable-claude-mem: full teardown, keep backup ---
setup
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
dis="$(jq '.enabledPlugins["claude-mem@thedotmack"]' "$CLAUDE_DIR/settings.json")"
keep="$(jq '.enabledPlugins["keep@me"]' "$CLAUDE_DIR/settings.json")"
cj_cm="$(jq '.mcpServers | has("claude-mem")' "$CLAUDE_JSON")"
cj_other="$(jq '.mcpServers | has("other")' "$CLAUDE_JSON")"
cache_gone=$([ ! -d "$CLAUDE_DIR/plugins/cache/thedotmack" ] && echo true || echo false)
db_gone=$([ ! -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && echo true || echo false)
backup_kept=$([ -f "$CLAUDE_MEM_DIR/claude-mem.db.premem0-20260627" ] && echo true || echo false)
{ [ "$dis" = false ] && [ "$keep" = true ] && [ "$cj_cm" = false ] && [ "$cj_other" = true ] \
  && [ "$cache_gone" = true ] && [ "$db_gone" = true ] && [ "$backup_kept" = true ]; } \
  && ok "disable tears down all layers, keeps backup" \
  || no "disable teardown (dis=$dis keep=$keep cm=$cj_cm other=$cj_other cache=$cache_gone db=$db_gone backup=$backup_kept)"
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1 && ok "disable idempotent" || no "disable idempotent (nonzero)"
teardown

# --- guard: no backup => live DB preserved ---
setup
rm -f "$CLAUDE_MEM_DIR"/*.premem0-*
bash "$MEM0CTL" disable-claude-mem >/dev/null 2>&1
[ -f "$CLAUDE_MEM_DIR/claude-mem.db" ] && ok "no-backup guard keeps live DB" || no "no-backup guard keeps live DB"
teardown

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash home/cli/claude/tests/test_mem0ctl.sh`
Expected: FAIL — `mem0ctl.sh` does not exist yet.

- [ ] **Step 3: Write `mem0ctl.sh` (skeleton + disable)**

```bash
#!/usr/bin/env bash
# mem0ctl — claude-mem decommission + mem0 enablement for dev hosts.
# Subcommands: disable-claude-mem | migrate | enable [--no-verify] | bootstrap
set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_MEM_DIR="${CLAUDE_MEM_DIR:-$HOME/.claude-mem}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS="$CLAUDE_DIR/settings.json"
INSTALLED="$CLAUDE_DIR/plugins/installed_plugins.json"
HOOK_DEST="$CLAUDE_DIR/hooks/mem0-recall-hook.sh"
RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # resources dir (siblings live here)
PROC_PATTERNS='worker-service\.cjs|claude-mem/.*/mcp-server\.cjs|chroma-mcp|uvx .*chroma-mcp'

log() { printf 'mem0ctl: %s\n' "$*" >&2; }

# Atomic jq edit; create {} if missing; leave file unchanged on jq error.
jq_inplace() {
  local file="$1"; shift
  local tmp; tmp="$(mktemp)"
  [ -s "$file" ] || printf '{}\n' > "$file"
  if jq "$@" "$file" > "$tmp" 2>/dev/null; then mv "$tmp" "$file"
  else rm -f "$tmp"; log "WARN: jq edit failed on $file (left unchanged)"; fi
}

kill_claude_mem() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local pids; pids="$(pgrep -f "$PROC_PATTERNS" || true)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 2
  pids="$(pgrep -f "$PROC_PATTERNS" || true)"
  # shellcheck disable=SC2086
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  return 0
}

disable_claude_mem() {
  log "stopping claude-mem processes…"
  kill_claude_mem

  log "disabling plugin across all layers…"
  jq_inplace "$SETTINGS" '.enabledPlugins["claude-mem@thedotmack"] = false'
  if [ -f "$CLAUDE_JSON" ]; then
    cp -f "$CLAUDE_JSON" "$CLAUDE_JSON.mem0ctl.bak"
    jq_inplace "$CLAUDE_JSON" 'walk(if type=="object"
      then with_entries(select(.key | test("claude-mem|thedotmack") | not)) else . end)'
  fi
  if [ -f "$INSTALLED" ]; then
    jq_inplace "$INSTALLED" 'walk(if type=="object"
      then with_entries(select(.key | test("claude-mem|thedotmack") | not)) else . end)'
  fi

  log "removing plugin cache…"
  rm -rf "$CLAUDE_DIR/plugins/cache/thedotmack"

  log "cleaning ~/.claude-mem live working set (keeping *.premem0-* + checkpoint)…"
  if [ -d "$CLAUDE_MEM_DIR" ]; then
    if ls "$CLAUDE_MEM_DIR"/*.premem0-* >/dev/null 2>&1; then
      rm -f "$CLAUDE_MEM_DIR"/claude-mem.db "$CLAUDE_MEM_DIR"/claude-mem.db-wal "$CLAUDE_MEM_DIR"/claude-mem.db-shm
      rm -rf "$CLAUDE_MEM_DIR"/chroma "$CLAUDE_MEM_DIR"/vector-db
    else
      log "WARN: no *.premem0-* backup — leaving claude-mem.db in place"
    fi
    rm -f "$CLAUDE_MEM_DIR"/worker.pid "$CLAUDE_MEM_DIR"/supervisor.json
  fi

  sleep 1
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "$PROC_PATTERNS" >/dev/null 2>&1; then
    log "WARN: claude-mem respawned — inspect $CLAUDE_JSON"
  else
    log "claude-mem disabled."
  fi
  return 0
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    disable-claude-mem) disable_claude_mem "$@";;
    migrate)            migrate "$@";;
    enable)             enable "$@";;
    bootstrap)          disable_claude_mem; enable "$@";;
    *) echo "usage: mem0ctl {disable-claude-mem|migrate [--db PATH] [--mode smoke|full]|enable [--no-verify]|bootstrap}" >&2; return 2;;
  esac
}
main "$@"
```

Note: `migrate` and `enable` are added in Tasks 5–6; until then `main` references them. To keep the file runnable for this task's test, add temporary stubs right above `main` and replace them in the next tasks:

```bash
migrate() { log "migrate: implemented in Task 6"; return 0; }
enable()  { log "enable: implemented in Task 5"; return 0; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x home/cli/claude/mem0ctl.sh && bash home/cli/claude/tests/test_mem0ctl.sh`
Expected: `3 passed, 0 failed`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck home/cli/claude/mem0ctl.sh`
Expected: clean (the `kill $pids` word-splitting is intentional and annotated).

- [ ] **Step 6: Commit**

```bash
git add home/cli/claude/mem0ctl.sh home/cli/claude/tests/test_mem0ctl.sh
git commit -m "feat(claude): mem0ctl disable-claude-mem (full local teardown)"
```

---

### Task 5: `mem0ctl enable` — hook install + SessionStart jq merge

**Files:**
- Modify: `home/cli/claude/mem0ctl.sh` (replace the `enable()` stub)
- Modify: `home/cli/claude/tests/test_mem0ctl.sh` (add enable cases)

**Interfaces:**
- Produces: `mem0ctl enable [--no-verify]` — installs hook for non-nix hosts (skips nix-store symlink), keyed replace-or-skip merge of the SessionStart group, warn-only connectivity check unless `--no-verify`.

- [ ] **Step 1: Add the failing enable tests**

Insert before the final summary in `tests/test_mem0ctl.sh`:

```bash
# --- enable: merge SessionStart, keep existing, idempotent ---
setup
MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable --no-verify >/dev/null 2>&1
n1="$(jq '.hooks.SessionStart | length' "$CLAUDE_DIR/settings.json")"
keep_existing="$(jq '[.hooks.SessionStart[].hooks[].command] | any(. == "/existing/other-hook.sh")' "$CLAUDE_DIR/settings.json")"
has_recall="$(jq '[.hooks.SessionStart[].hooks[].command] | any(endswith("mem0-recall-hook.sh"))' "$CLAUDE_DIR/settings.json")"
{ [ "$n1" = 2 ] && [ "$keep_existing" = true ] && [ "$has_recall" = true ]; } \
  && ok "enable adds recall, keeps existing group" || no "enable merge (len=$n1 keep=$keep_existing recall=$has_recall)"
MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable --no-verify >/dev/null 2>&1
n2="$(jq '.hooks.SessionStart | length' "$CLAUDE_DIR/settings.json")"
[ "$n2" = 2 ] && ok "enable idempotent (no duplicate group)" || no "enable idempotent (len=$n2)"
# connectivity failure without --no-verify still exits 0
MEM0_URL="http://127.0.0.1:1" bash "$MEM0CTL" enable >/dev/null 2>&1 && ok "enable warn-only on unreachable" || no "enable warn-only on unreachable (nonzero)"
teardown
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash home/cli/claude/tests/test_mem0ctl.sh`
Expected: the three enable assertions FAIL (stub does nothing; `SessionStart` length stays 1).

- [ ] **Step 3: Replace the `enable()` stub**

```bash
enable() {
  local verify=1
  [ "${1:-}" = "--no-verify" ] && verify=0

  # Install hook for ad-hoc (non-nix) hosts; skip if already a nix-store symlink.
  if [ -L "$HOOK_DEST" ] && readlink "$HOOK_DEST" | grep -q '/nix/store/'; then
    log "recall hook is nix-managed — skipping copy"
  else
    mkdir -p "$(dirname "$HOOK_DEST")"
    cp "$RES/mem0-recall-hook.sh"   "$HOOK_DEST"
    cp "$RES/mem0_recall_format.py" "$(dirname "$HOOK_DEST")/mem0_recall_format.py"
    chmod +x "$HOOK_DEST"
    log "installed recall hook → $HOOK_DEST"
  fi

  # Keyed replace-or-skip merge of the SessionStart recall group.
  jq_inplace "$SETTINGS" --arg cmd "$HOOK_DEST" '
    .hooks //= {} | .hooks.SessionStart //= [] |
    .hooks.SessionStart |=
      ( map(select(any(.hooks[]?; (.command // "") | endswith("mem0-recall-hook.sh")) | not))
        + [ { hooks: [ { type: "command", command: $cmd, timeout: 5 } ] } ] )'
  log "wired SessionStart recall hook into settings.json"

  if [ "$verify" -eq 1 ]; then
    if curl -fsS --connect-timeout 1 --max-time 2 \
         -X POST -H 'Content-Type: application/json' \
         -d "{\"user_id\":\"$MEM0_USER_ID\",\"search_query\":\"healthcheck\",\"page\":1,\"size\":1}" \
         "$MEM0_URL/api/v1/memories/filter" >/dev/null 2>&1; then
      log "mem0 reachable at $MEM0_URL"
    else
      log "WARN: mem0 not reachable at $MEM0_URL (off-tailnet?) — hook will fail-open"
    fi
  fi
  return 0
}
```

- [ ] **Step 4: Run the full shell test to verify pass**

Run: `bash home/cli/claude/tests/test_mem0ctl.sh`
Expected: `6 passed, 0 failed`.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck home/cli/claude/mem0ctl.sh`
Expected: clean.

```bash
git add home/cli/claude/mem0ctl.sh home/cli/claude/tests/test_mem0ctl.sh
git commit -m "feat(claude): mem0ctl enable (idempotent SessionStart jq merge)"
```

---

### Task 6: `mem0ctl migrate` + finalize dispatch

**Files:**
- Modify: `home/cli/claude/mem0ctl.sh` (replace the `migrate()` stub)

**Interfaces:**
- Produces: `mem0ctl migrate [--db PATH] [--mode smoke|full]` — defaults `--db` to the newest `*.premem0-*`, runs the vendored tool via `uv run --with httpx`, writing the checkpoint to a writable path (the store copy is read-only).

- [ ] **Step 1: Replace the `migrate()` stub**

```bash
migrate() {
  local db="" mode="full"
  while [ $# -gt 0 ]; do
    case "$1" in
      --db)   db="$2"; shift 2;;
      --mode) mode="$2"; shift 2;;
      *) log "unknown migrate arg: $1"; return 2;;
    esac
  done
  if [ -z "$db" ]; then
    db="$(ls -t "$CLAUDE_MEM_DIR"/*.premem0-* 2>/dev/null | grep -vE '\-(wal|shm)$' | head -1 || true)"
  fi
  [ -n "$db" ] && [ -f "$db" ] || { log "no migration DB found (pass --db PATH)"; return 1; }
  command -v uv >/dev/null 2>&1 || { log "uv not found on PATH"; return 1; }
  local ckpt="$CLAUDE_MEM_DIR/mem0-migrate-checkpoint.json"
  log "migrating $db → $MEM0_URL (mode=$mode, checkpoint=$ckpt)…"
  uv run --project "$RES/mem0-migrate" --with httpx mem0-migrate \
    --db "$db" --url "$MEM0_URL" --user-id "$MEM0_USER_ID" --mode "$mode" --checkpoint "$ckpt"
}
```

Also delete the temporary `migrate()`/`enable()` stubs added in Task 4 (the real `enable` landed in Task 5; the real `migrate` lands here — ensure no stub remains).

- [ ] **Step 2: Verify usage + arg parsing without touching the network**

Run:
```bash
shellcheck home/cli/claude/mem0ctl.sh
CLAUDE_MEM_DIR="$(mktemp -d)" home/cli/claude/mem0ctl.sh migrate ; echo "exit=$?"
```
Expected: shellcheck clean; migrate prints `no migration DB found` and `exit=1` (no DB in the empty temp dir — confirms guard works).

- [ ] **Step 3: Re-run full shell tests (no regression)**

Run: `bash home/cli/claude/tests/test_mem0ctl.sh`
Expected: `6 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add home/cli/claude/mem0ctl.sh
git commit -m "feat(claude): mem0ctl migrate via vendored uv tool"
```

---

### Task 7: Nix module + wire into home-manager

**Files:**
- Create: `home/cli/claude/default.nix`
- Modify: `home/cli/default.nix` (add `./claude` to imports)

**Interfaces:**
- Consumes: `mem0ctl.sh`, `mem0-recall-hook.sh`, `mem0_recall_format.py`, `mem0-migrate/` (all in this dir).
- Produces: `mem0ctl` on `PATH` (deps bundled), `~/.claude/hooks/{mem0-recall-hook.sh,mem0_recall_format.py}` as store symlinks, and a `home.activation.mem0Enable` that runs `mem0ctl enable --no-verify`.

- [ ] **Step 1: Write the module**

```nix
# home/cli/claude/default.nix
{ pkgs, lib, ... }:
let
  runtimeDeps = with pkgs; [ curl jq python3 uv gnugrep coreutils procps ];
  mem0ctlPkg = pkgs.stdenv.mkDerivation {
    pname = "mem0ctl";
    version = "1.0.0";
    src = ./.;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/mem0ctl" "$out/bin"
      cp ${./mem0ctl.sh}            "$out/share/mem0ctl/mem0ctl.sh"
      cp ${./mem0-recall-hook.sh}   "$out/share/mem0ctl/mem0-recall-hook.sh"
      cp ${./mem0_recall_format.py} "$out/share/mem0ctl/mem0_recall_format.py"
      cp -R ${./mem0-migrate}       "$out/share/mem0ctl/mem0-migrate"
      chmod +x "$out/share/mem0ctl/mem0ctl.sh" "$out/share/mem0ctl/mem0-recall-hook.sh"
      makeWrapper "$out/share/mem0ctl/mem0ctl.sh" "$out/bin/mem0ctl" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
      runHook postInstall
    '';
  };
in
{
  home.packages = [ mem0ctlPkg ];

  # Declarative recall hook + its formatter sibling (store symlinks).
  home.file.".claude/hooks/mem0-recall-hook.sh".source =
    "${mem0ctlPkg}/share/mem0ctl/mem0-recall-hook.sh";
  home.file.".claude/hooks/mem0_recall_format.py".source =
    "${mem0ctlPkg}/share/mem0ctl/mem0_recall_format.py";

  # Imperative settings.json merge on every rebuild — fail-soft, no network.
  home.activation.mem0Enable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${lib.makeBinPath runtimeDeps}:$PATH" \
      "${mem0ctlPkg}/bin/mem0ctl" enable --no-verify || true
  '';
}
```

- [ ] **Step 2: Add the import**

In `home/cli/default.nix`, add `./claude` to the `imports` list (alongside `./bat`, `./git`, `./starship`):

```nix
  imports = [
    ./bat
    ./claude
    ./git
    ./starship
    # …unchanged…
  ];
```

- [ ] **Step 3: Build the configuration (no switch yet)**

Run: `darwin-rebuild build --flake .#$(scutil --get LocalHostName) 2>&1 | tail -20`
(Use the host attr that matches `hosts/`; if unsure, run `nix flake show` to list `darwinConfigurations`.)
Expected: build succeeds; output references a new system closure. No evaluation errors about `home/cli/claude`.

- [ ] **Step 4: Sanity-check the built artifacts in the store**

Run:
```bash
ls -l ./result/sw/bin/mem0ctl 2>/dev/null || nix path-info .#darwinConfigurations.*.config.system.build.toplevel >/dev/null
# Confirm the wrapper resolves its resources:
mem0ctl_pkg="$(nix-store -qR ./result | grep -m1 mem0ctl || true)"; echo "$mem0ctl_pkg"
```
Expected: a `mem0ctl` derivation path is present in the closure.

- [ ] **Step 5: Commit**

```bash
git add home/cli/claude/default.nix home/cli/default.nix
git commit -m "feat(claude): home-manager module wiring (mem0ctl + recall hook + activation)"
```

---

### Task 8: End-to-end on the host (cutover) — verification gate

**Files:** none (operational verification).

This task is the gate that must pass before Task 9 deletes anything from olympus-sdk.

- [ ] **Step 1: Switch the configuration**

Run: `darwin-rebuild switch --flake .#<host>`
Expected: activation runs `mem0Enable`; no errors. `~/.claude/hooks/mem0-recall-hook.sh` is now a symlink into `/nix/store/...`.

- [ ] **Step 2: Tear down the live claude-mem daemons**

Run: `mem0ctl bootstrap`
Expected: logs "stopping claude-mem processes…", disables across layers, "claude-mem disabled."

- [ ] **Step 3: Verify no claude-mem processes remain**

Run: `pgrep -fl 'worker-service\.cjs|claude-mem/.*/mcp-server\.cjs|chroma-mcp' || echo "none"`
Expected: `none`. If any remain, a claude-mem daemon survived — inspect `installed_plugins.json` / plugin cache and re-run; do not proceed to Task 9.

- [ ] **Step 4: Verify settings + recall wiring**

Run:
```bash
jq '.enabledPlugins["claude-mem@thedotmack"]' ~/.claude/settings.json
jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("mem0-recall-hook.sh")))' ~/.claude/settings.json
```
Expected: `false`; exactly one recall-hook command listed.

- [ ] **Step 5: Verify recall connectivity + compact output**

Run: `echo '{"cwd":"'"$PWD"'"}' | ~/.claude/hooks/mem0-recall-hook.sh`
Expected (on-tailnet): a `hookSpecificOutput` JSON whose `additionalContext` begins `Recalled N memories for olympus-sdk — top 3:` with ≤3 short lines. Off-tailnet: `{"continue":true}`.

- [ ] **Step 6: Smoke-test migrate (idempotent — already-migrated rows are checkpointed)**

Run: `mem0ctl migrate --mode smoke`
Expected: runs against the newest `*.premem0-*`, posts a small batch, exits 0. (Safe/resumable per the tool's checkpoint.)

- [ ] **Step 7: Confirm the backup survived**

Run: `ls ~/.claude-mem/*.premem0-* ~/.claude-mem/mem0-migrate-checkpoint.json`
Expected: both still present. `claude-mem.db`, `chroma/`, `vector-db/` are gone.

- [ ] **Step 8: Open the nix-darwin-hm PR**

```bash
git push -u origin feature/mem0-host-enablement
gh pr create --title "feat(claude): mem0 host enablement + claude-mem decommission" \
  --body "Implements docs/superpowers/specs/2026-06-28-mem0-host-enablement-design.md. New home/cli/claude module: mem0ctl (disable/migrate/enable/bootstrap), compact recall hook, vendored mem0-migrate tool, nix activation. Verified end-to-end on host (Task 8)."
```

---

### Task 9: Remove the migration tool from olympus-sdk (separate PR)

**Files (in `~/projects/personal/olympus-sdk`):**
- Delete: `tools/mem0-migrate/`
- Modify: any file referencing it as a *live* tool (verify with grep below).

**Do not start until Task 8 has fully passed and PR 1 is merged.**

- [ ] **Step 1: Branch in olympus-sdk**

```bash
cd ~/projects/personal/olympus-sdk
git checkout main && git pull
git checkout -b chore/remove-mem0-migrate
```

- [ ] **Step 2: Inventory references**

Run: `grep -rn "mem0-migrate\|mem0_migrate" --include='*.md' --include='*.nix' --include='*.toml' . | grep -v docs/superpowers/plans/archive`
Expected: a finite list — `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` key-file tables, the mem0 plan/spec docs. Record them.

- [ ] **Step 3: Delete the tool**

```bash
git rm -r tools/mem0-migrate
```

- [ ] **Step 4: Scrub live-tool references**

For each hit from Step 2: in the key-file location tables and any "how to run migration" prose, replace the olympus-sdk path with a one-line pointer: *"mem0-migrate relocated to nix-darwin-hm `home/cli/claude/mem0-migrate` (run via `mem0ctl migrate`)."* Leave historical narrative in `docs/superpowers/plans/` and `specs/` intact (it records what happened); just add the pointer where a reader would look for the live tool.

- [ ] **Step 5: Verify nothing else breaks**

Run: `grep -rn "tools/mem0-migrate" . || echo "no live path refs remain"`
Expected: `no live path refs remain`.

- [ ] **Step 6: Commit + PR**

```bash
git add -A
git commit -m "chore(mem0): relocate mem0-migrate to nix-darwin-hm"
git push -u origin chore/remove-mem0-migrate
gh pr create --title "chore(mem0): relocate mem0-migrate to nix-darwin-hm" \
  --body "mem0-migrate moved to nix-darwin-hm home/cli/claude (run via mem0ctl). Host enablement PR merged + verified. Historical plan/spec docs retain context with a pointer to the new location."
```

---

## Self-Review

**Spec coverage:**
- Module location `home/cli/claude/` → Tasks 1–7. ✓
- `home.file` (script+hook) + `home.activation` (enable) → Task 7. ✓
- Python migrate tool moved, no olympus-sdk dep, kept in Python → Task 1, Task 9. ✓
- Full claude-mem teardown across 3 layers + cache + live set, keep backup → Task 4. ✓
- Keyed replace-or-skip SessionStart merge, missing-file safe, atomic → Task 5. ✓
- Declarative hook vs imperative settings split; ad-hoc self-install skips nix symlink → Tasks 5, 7. ✓
- Compact header+count+top-3 recall output → Tasks 2–3. ✓
- `enable --no-verify` in activation (no rebuild network) → Tasks 5, 7. ✓
- Extracted, unit-testable formatter → Task 2. ✓
- POSIX shell tests, no bats; shellcheck → Tasks 4–6. ✓
- Cross-repo two-PR sequencing, deletion gated on Task 8 → Tasks 8, 9. ✓
- uv bundled (no dev.nix change) → Task 7 (deviation from spec's "add uv to dev profile" — self-contained wrapper is cleaner and matches "everything in the module"). ✓

**Placeholder scan:** Temporary `migrate`/`enable` stubs in Task 4 are explicitly replaced in Tasks 5–6 (Task 6 Step 1 calls out stub removal) — intentional, not a placeholder. No TBD/TODO elsewhere.

**Type/name consistency:** `mem0ctl` subcommands (`disable-claude-mem`, `migrate`, `enable`, `bootstrap`), `format_block(...)`, env vars (`CLAUDE_DIR`, `CLAUDE_MEM_DIR`, `CLAUDE_JSON`, `MEM0_URL`, `MEM0_USER_ID`, `MEM0_TOP_K`), `RES` resources dir, and `HOOK_DEST` are used consistently across tasks and the nix module.
