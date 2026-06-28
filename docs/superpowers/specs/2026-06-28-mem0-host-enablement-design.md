# Design: mem0 host enablement + claude-mem decommission

**Date:** 2026-06-28
**Repo (primary):** `nix-darwin-hm`
**Related:** olympus-sdk epic #123 (mem0/OpenMemory platform). This spec supersedes
the *host-side* concerns of olympus-sdk's
`docs/superpowers/plans/2026-06-27-mem0-memory-platform.md` (P-host) — leave a
one-line pointer there back to this file.

## Problem

The mem0/OpenMemory migration (epic #123) moved 11,578 memories off claude-mem
into the self-hosted mnemosyne store. But the **host side was never finished or
made reproducible**:

1. **claude-mem is still alive and self-respawning.** On the primary dev host,
   despite `enabledPlugins["claude-mem@thedotmack"] = false` in
   `~/.claude/settings.json`, there are 6+ `worker-service.cjs --daemon`
   processes (one spawned per session start), 5+ `mcp-server.cjs` processes, and
   a live `chroma-mcp` vector-DB syncer. The live `claude-mem.db` was being
   written as recently as the migration cutover. The `false` flag is only **one
   of three enable layers** — the daemons are actually launched via
   `~/.claude.json` (per-project MCP/plugin registration) and
   `installed_plugins.json`. Two memory systems run in parallel.

2. **The mem0 recall hook is hand-placed, not reproducible.** The SessionStart
   recall hook (`~/.claude/hooks/mem0-recall-hook.sh`) and its `settings.json`
   wiring exist only by hand on one machine. A freshly nix-profiled host gets
   nothing. `~/.claude` is entirely outside nix today.

3. **Recall output isn't visible at session start.** The hook *does* run, but its
   ~10.7KB output trips the harness persist threshold and is saved to a file
   instead of shown inline — so it reads as "not working."

4. **The migration tool lives in the wrong repo.** `tools/mem0-migrate/`
   (Python/uv, tested) sits in olympus-sdk, coupling a host-profiling concern to
   an application repo.

## Goals

- One reproducible, idempotent, fail-soft mechanism to **decommission claude-mem**,
  **migrate** (re-runnable), and **enable mem0** on any nix-profiled dev host.
- Make it work **both** declaratively via nix (`darwin-rebuild`) **and** ad-hoc
  outside nix (a script on `PATH`).
- Remove all host/mem0 coupling from olympus-sdk.

## Non-goals

- No changes to the server-side OpenMemory/mem0 deployment (olympus k3s, epic #123).
- No remote teardown — the claude-mem cluster server-beta is already retired
  (project memory, 2026-06-27). Disable is **local-only**.
- No re-architecture of how Claude Code itself manages plugins.

## Decisions (locked with user)

| Decision | Choice |
|---|---|
| Where it lives | Everything in **nix-darwin-hm** (new `home/cli/claude/` module). olympus-sdk keeps nothing mem0/host. |
| Nix mechanism | **Both** — `home.file` installs script to `PATH`; `home.activation` runs idempotent `enable` on every rebuild. |
| Migration tool | **Move the Python tool into nix-darwin-hm** (kept in Python — it's tested). No dependency on olympus-sdk. |
| claude-mem removal | **Full local teardown** (it's alive, not a no-op). Keep the `*.premem0-*` backup + migrate checkpoint. **Delete** the live working set. |
| Recall output | **Compact header + count + top-3 truncated**, inline-visible. |
| Spec location | **nix-darwin-hm** (this file). |

## Architecture

A new home-manager module **`home/cli/claude/`**:

```
nix-darwin-hm/home/cli/claude/
  default.nix            # module: packages, home.file (script + hook), home.activation (enable --no-verify)
  mem0ctl.sh             # canonical unified script — source of truth, subcommand-dispatched
  mem0-recall-hook.sh    # SessionStart recall hook (thin bash wrapper)
  mem0_recall_format.py  # extracted, unit-testable formatter (header + count + top-3 truncated)
  mem0-migrate/          # Python tool MOVED from olympus-sdk (src/ + tests/ + pyproject.toml)
  tests/
    test_mem0ctl.sh      # POSIX shell tests (no bats dep) + shellcheck
```

Wired into `home/cli/default.nix` imports. Adds `uv` to `modules/profiles/dev.nix`
(`curl`, `jq`, `python3` already present in base/dev profiles).

### Declarative vs imperative split (committed)

- **Recall hook = declarative.** `home.file` symlinks
  `~/.claude/hooks/mem0-recall-hook.sh` (and `mem0_recall_format.py`) from the nix
  store via `pkgs.writeShellScriptBin` / `writeTextFile`. Free shellcheck at build,
  version-pinned, immutable.
- **`settings.json` = imperative jq merge.** That file is **also written by Claude
  Code itself** (plugin toggles, `/config`, permission appends). It cannot be a
  declarative `home.file` without clobbering the app's own state. So the
  SessionStart wiring + plugin-disable are applied by an idempotent jq merge in the
  `enable` / `disable-claude-mem` subcommands.
- **Ad-hoc parity:** the script's `enable` self-installs the hook **only when
  `~/.claude/hooks/mem0-recall-hook.sh` is not already a nix-store symlink** (detect
  symlink → skip). That is the non-nix-machine path; on a nix host, `home.file`
  owns the hook and `enable` only touches `settings.json` + verification.

## Components

### 1. `mem0ctl` — unified script

Subcommand-dispatched. Every subcommand is **idempotent** and **fail-soft**
(never aborts a `darwin-rebuild`; non-zero only on explicit ad-hoc misuse).

Config via env with baked defaults:
`MEM0_URL` (`http://openmemory.raptor-mimosa.ts.net:8765`),
`MEM0_USER_ID` (`mnemosyne`).

| Subcommand | Behavior |
|---|---|
| `disable-claude-mem` | Full local teardown — see §1a. |
| `migrate [--db PATH] [--mode smoke\|full]` | Locates the vendored `mem0-migrate` Python tool, runs `uv run mem0-migrate ...` against `$MEM0_URL`. Resumable/checkpointed (logic unchanged). Default `--db` = newest `~/.claude-mem/*.premem0-*` (non-wal/shm). |
| `enable [--no-verify]` | Installs recall hook (ad-hoc only; skips nix-store symlink), merges SessionStart wiring into `~/.claude/settings.json` (§1b), verifies `MEM0_URL` connectivity unless `--no-verify` (warn-only). |
| `bootstrap` | `disable-claude-mem` → `enable`. (`migrate` is **not** in bootstrap — it's a one-time op; run explicitly.) |

#### 1a. `disable-claude-mem` teardown

1. **Kill** running procs by command-pattern (graceful TERM, then KILL):
   `worker-service.cjs --daemon`, `claude-mem/.../mcp-server.cjs`, `chroma-mcp`,
   the `uv tool uvx ... chroma-mcp` parent. Match on full command string to avoid
   killing unrelated `uv`/`node`/`bun` processes.
2. **Disable across all 3 layers** (jq, idempotent):
   - `~/.claude/settings.json` → `enabledPlugins["claude-mem@thedotmack"] = false`.
   - `~/.claude.json` → remove/disable any `claude-mem` / `thedotmack` entries
     (per-project MCP + plugin registration; also holds plugin/skill usage telemetry).
     The authoritative install record is `~/.claude/plugins/installed_plugins.json`;
     leftover daemons and the plugin cache are handled by the process-kill (step 1) and
     cache removal (step 3).
   - `~/.claude/plugins/installed_plugins.json` → mark claude-mem uninstalled/disabled.
3. **Remove** plugin cache `~/.claude/plugins/cache/thedotmack/`.
4. **Clean `~/.claude-mem/` runtime + live working set**, **deleting**:
   `worker.pid`, `supervisor.json`, `claude-mem.db` (+ `-wal`/`-shm`), `chroma/`,
   `vector-db/`. **Keep**: `*.premem0-*` backup files and
   `mem0-migrate-checkpoint.json`.
5. **Re-verify** (success gate): re-scan processes; if any claude-mem proc
   respawned within a short grace window, report it (a claude-mem process is still
   running — inspect the layers cleaned in step 2). Idempotent: a second run finds
   nothing to do and exits clean.

#### 1b. `settings.json` SessionStart merge (the core engineering)

`hooks.SessionStart` is an array of groups `{hooks:[{type,command,timeout}]}`.
A naive jq append duplicates the recall group on **every** rebuild → hook fires
twice. The merge is **keyed replace-or-skip**:

- **Match key:** a SessionStart group containing a hook whose `command` ends with
  `mem0-recall-hook.sh`.
- **If present:** replace that group in place (idempotent; lets us update the
  command/timeout).
- **If absent:** append exactly one group.
- **Missing/empty file:** start from `{}`; create `hooks.SessionStart = []`.
- Write atomically (temp + mv). Never rewrite unrelated keys.

Sketch:
```bash
jq --arg cmd "$HOOK_PATH" '
  .hooks //= {} | .hooks.SessionStart //= [] |
  .hooks.SessionStart
    |= ( map(select(any(.hooks[]?; .command | endswith("mem0-recall-hook.sh")) | not))
         + [ { hooks: [ { type: "command", command: $cmd, timeout: 5 } ] } ] )
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 2. `mem0-recall-hook.sh` + `mem0_recall_format.py`

Thin bash wrapper keeps the existing fail-open contract (any error →
`{"continue":true}`, exit 0; 2s curl budget against `/api/v1/memories/filter`).
The **formatting** moves into `mem0_recall_format.py` so it's unit-testable.

Compact output (replaces the verbose block):
```
Recalled <N> memories for <basename(cwd)> — top 3:
1. <memory truncated to ~200 chars, single line>
2. ...
3. ...
```
`N` = total hits; only the top 3 are shown, each truncated to one line. Keeps the
SessionStart `additionalContext` well under the harness persist threshold so it
renders inline. Empty/valid-but-no-hits response → `{"continue":true}` (no block).

### 3. Migration tool (moved, unchanged logic)

`tools/mem0-migrate/` (olympus-sdk) → `home/cli/claude/mem0-migrate/`
(nix-darwin-hm), verbatim: `src/mem0_migrate/{db,compose,checkpoint,run}.py`,
`tests/`, `pyproject.toml` (`[project.scripts] mem0-migrate = ...`), README. No
olympus-sdk-specific deps (standalone uv project). Invoked by `mem0ctl migrate`
via `uv run`.

## Nix wiring (`home/cli/claude/default.nix`)

- `home.packages` / profile: ensure `uv` available (add to `modules/profiles/dev.nix`).
- `home.file."${homeDir}/.claude/hooks/mem0-recall-hook.sh"` → store symlink
  (`writeShellScriptBin` wrapper) ; same for `mem0_recall_format.py`.
- `mem0ctl` onto `PATH` via `pkgs.writeShellApplication { runtimeInputs = [ curl jq python3 uv ]; }`
  (build-time shellcheck).
- `home.activation.mem0Enable = lib.hm.dag.entryAfter ["writeBoundary"] '' ${mem0ctl}/bin/mem0ctl enable --no-verify || true '';`
  — idempotent, fail-soft, no network on rebuild.

`disable-claude-mem` is **not** in activation (it kills processes — too aggressive
for an unattended rebuild). It is run explicitly, or once via `bootstrap` during
cutover.

## Cross-repo sequencing (safety gate — two PRs)

The olympus-sdk deletion is the only irreversible step; gate it on the new copy
being proven.

- **PR 1 (nix-darwin-hm):** add `home/cli/claude/` module (script, hook,
  formatter, moved Python tool, tests, nix wiring). Gate to green:
  `uv run pytest` (Python), shell tests + shellcheck (mem0ctl), formatter unit
  test, `darwin-rebuild build` / `nix flake check`, and a real end-to-end
  `mem0ctl migrate --mode smoke` + `enable` on the host.
- **PR 2 (olympus-sdk):** delete `tools/mem0-migrate/`; scrub live-tool refs in
  `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` and the mem0 plan doc (leave historical
  plan/spec narrative intact + add the pointer to this spec). Only after PR 1 is
  merged and proven.

## Error handling

- All `mem0ctl` subcommands fail-soft in the activation path (`|| true`); explicit
  ad-hoc runs surface non-zero on real misuse.
- `enable` connectivity check is warn-only (host may be off-tailnet); skipped
  entirely with `--no-verify` (the activation default).
- Recall hook keeps strict fail-open.
- jq merges are atomic (temp + mv) and never clobber unrelated keys.
- `disable-claude-mem` process-kill matches on full command string to avoid
  collateral kills.

## Testing (required — must pass before commit, per project rule)

- **Python migrate tool:** existing pytest suite travels with it →
  `uv run pytest` green in nix-darwin-hm.
- **`mem0ctl` (POSIX shell tests, no bats):** against a temp `$HOME`:
  - `enable` merges SessionStart **without** dropping pre-existing hook groups.
  - `enable` run twice → no diff (keyed replace, no duplicate group).
  - `disable-claude-mem` sets all 3 layers; idempotent second run is a clean no-op;
    keeps `*.premem0-*`, deletes the live working set; never touches the backup.
  - connectivity failure under `enable` (no `--no-verify`) warns but exits 0.
  - shellcheck clean (also enforced by `writeShellApplication`).
- **Recall formatter (`mem0_recall_format.py`):** unit test against a sample API
  response → header + correct `N`, ≤3 items, ~200-char truncation, empty-response
  → no block / fail-open.
- **Nix:** `darwin-rebuild build` (or `nix flake check`) succeeds with the new
  module; activation is dry-run-safe and adds no network call.

## Rollout

1. PR 1 merged → `darwin-rebuild switch` on the primary host.
2. Run `mem0ctl bootstrap` once to tear down the live claude-mem daemons + clean
   state (activation alone won't kill processes).
3. Verify: no claude-mem processes; new session shows the compact recall block
   inline; `mem0ctl migrate --mode smoke` succeeds.
4. PR 2 (olympus-sdk cleanup).
