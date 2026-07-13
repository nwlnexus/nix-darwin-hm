# GitNexus Graph Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the gitnexus code graph complete and current across the fleet — every repo in `repos.toml` gets a graph (today: 3 of 11), refreshed on the existing sweep, without ever writing to a dev clone. Also make gitnexus's agent integration (skills/hooks/MCP) reproducible in nix, which it is not today.

**Architecture:** Extend the phase 1 `repomix-pack` runner with a **graph stage**. Analyze runs in the clean origin checkout phase 1 already builds; the graph is *stored* in `~/.cache` and its registry entry is **re-anchored** at the dev clone. Dev clones stay pristine. The refreshed stable `<!-- gitnexus:start -->` section rides the existing `automation/repomix-pack` PR beside the pack. One sweep, two artifacts.

**Tech Stack:** Nix (home-manager `home.activation`), mise global `npm:gitnexus` (v1.6.9), Bun/TypeScript, `git`, `gh`.

**Spec:** [`docs/superpowers/specs/2026-07-12-gitnexus-graph-freshness-design.md`](../specs/2026-07-12-gitnexus-graph-freshness-design.md)

**Epic:** [nwlnexus/nix-darwin-hm#30](https://github.com/nwlnexus/nix-darwin-hm/issues/30) — all tasks below are native sub-issues (#31–#38) of this epic.

## Global Constraints

- **Never write to a dev clone.** Inherited verbatim from phase 1. Graph *storage* lives only under `~/.cache/repomix-pipeline/`; the dev clone is referenced by the registry but never written to by the runner. (gitnexus's own `rename` MCP tool writes there — that is the user's tool, not the sweep.)
- **`analyze` is invoked with `--no-stats --skip-skills`.** `--no-stats` omits the volatile symbol counts that would otherwise churn `CLAUDE.md` on every run. `--skip-skills` is only safe because Task 1 makes the skills nix-managed fleet-wide — **do not add `--skip-skills` before Task 1 lands.**
- **Never invoke gitnexus from inside a cache checkout.** mise refuses to run in an untrusted config dir and the checkout carries the repo's own `mise.toml`. See Task 3.
- **`~/.gitnexus/registry.json` is shared mutable state.** All writes go through `registry.ts` (exclusive lock + atomic replace). The **graph stage runs serially** even though the pack stage stays parallel.
- **The PR gate is "any staged diff against base"**, not "pack hash changed". A graph-only refresh must still open a PR.
- Graph freshness is **local-sweep-only** — no CI. The graph is a 41–318 MB local binary CI has nowhere to publish. Accepted asymmetry (spec §5).
- Never auto-merge. Deterministic branch `automation/repomix-pack` (unchanged from phase 1).
- Test with `bun test`.

---

## Tracking Protocol (REQUIRED — keep in sync)

Identical to phase 1. This work is tracked in **both** this plan file and GitHub issues. Neither is authoritative alone; keep them consistent.

- **Epic issue:** the parent tracks the whole phase. Each task below maps to a **native GitHub sub-issue** of the epic (see the Ticket Map).
- **On starting a task:** check the task's first `- [x]` here, set the sub-issue to in-progress (assign yourself / add `status:in-progress` label), and comment the branch/worktree you are using.
- **On finishing a task:** check every `- [x]` step here, comment the merged PR/commit SHA on the sub-issue, and **close the sub-issue**. GitHub auto-updates the epic's sub-issue progress bar.
- **Cross-linking:** every sub-issue body links back to this plan and its task heading; this plan's Ticket Map links each task to its sub-issue. PRs must reference their sub-issue (`Closes #<n>`).
- **Progress source of truth for humans:** the epic issue's sub-issue checklist. Keep the plan checkboxes matching it.

### Ticket Map

| Task | Sub-issue | Depends on | Parallel group |
| --- | --- | --- | --- |
| 1. Nix: gitnexus agent integration | [#31](https://github.com/nwlnexus/nix-darwin-hm/issues/31) | — | A |
| 2. `registry.ts` — locked, atomic registry | [#32](https://github.com/nwlnexus/nix-darwin-hm/issues/32) | — | A |
| 3. `graph.ts` — gate, analyze, re-anchor | [#33](https://github.com/nwlnexus/nix-darwin-hm/issues/33) | 2 | B |
| 4. Config: `graph` opt-out + dev-clone path | [#34](https://github.com/nwlnexus/nix-darwin-hm/issues/34) | — | A |
| 5. Generalize the PR gate | [#35](https://github.com/nwlnexus/nix-darwin-hm/issues/35) | — | A |
| 6. Orchestration + CLI + disk budget | [#36](https://github.com/nwlnexus/nix-darwin-hm/issues/36) | 3,4,5 | C |
| 7. Integration test + single-repo pilot | [#37](https://github.com/nwlnexus/nix-darwin-hm/issues/37) | 6 | D |
| 8. Fan-out: personal group, then work | [#38](https://github.com/nwlnexus/nix-darwin-hm/issues/38) | 7 | E |

---

## Parallelization Strategy (preferred wherever possible)

- **Group A (start immediately, fully independent):** Tasks 1, 2, 4, 5 touch disjoint files (`home/cli/claude/default.nix`, `src/registry.ts`, `src/config.ts` + `repos.toml`, `src/git-pr.ts`). Dispatch all four concurrently.
- **Group B:** Task 3 consumes `registry.ts` from Task 2.
- **Group C (join):** Task 6 wires everything together — the single synchronization point.
- **Group D:** Task 7 (integration + pilot).
- **Group E:** Task 8 (fan-out), last.

When executing with subagents, launch each parallel group as a single batch of concurrent dispatches. Only serialize across group boundaries. Record in each sub-issue which group/batch it ran in.

---

## File Structure

- `home/cli/claude/default.nix` — **modify**: add the gitnexus `home.activation` entry (Task 1).
- `modules/repomix/repos.toml` — **modify**: optional per-repo `graph = false` (Task 4).
- `scripts/repomix-pack/src/registry.ts` — **create**: locked/atomic `~/.gitnexus/registry.json` access (Task 2).
- `scripts/repomix-pack/src/graph.ts` — **create**: commit gate, `analyze` invocation, re-anchor (Task 3).
- `scripts/repomix-pack/src/config.ts` — **modify**: `graph` flag + `devClonePath` on `RepoTarget` (Task 4).
- `scripts/repomix-pack/src/types.ts` — **modify**: extend `RepoTarget` (Task 4).
- `scripts/repomix-pack/src/git-pr.ts` — **modify**: generalized gate + stage `CLAUDE.md`/`AGENTS.md` (Task 5).
- `scripts/repomix-pack/src/index.ts` — **modify**: graph stage, serial, CLI flags, disk log (Task 6).

Test files live beside their module as `*.test.ts`.

---

## Task 1: Nix — gitnexus agent integration (reproducible skills/hooks/MCP)

**Why first:** independently valuable, and it is what makes `--skip-skills` (Task 3) safe fleet-wide. It also fixes a bug that exists **today**: gitnexus's 7 skills, its hooks, and its MCP registration were written by an imperative one-off `gitnexus setup` on a single machine and live nowhere in nix. A fresh nix-darwin host gets the binary and none of the integration.

**Files:**
- Modify: `home/cli/claude/default.nix`

**Interfaces:**
- Produces: gitnexus skills + hooks + MCP registration present on **every** nix-darwin host after rebuild. Consumed by Task 3's `--skip-skills`.

- [ ] **Step 1: Resolve the gitnexus binary in nix.** It is a mise global (`npm:gitnexus`), not a nixpkgs package, so it is not on the activation script's `PATH` by default. Resolve it from the mise install prefix (`~/.local/share/mise/installs/npm-gitnexus/latest/bin/gitnexus`). Guard on existence — if mise has not installed it yet on a fresh host, the activation must **no-op, not fail**.

- [ ] **Step 2: Add the activation entry**, following the existing `home.activation.mem0Enable` precedent (same file, ~line 91) — imperative, idempotent, fail-soft:

```nix
# gitnexus ships its own installer; it is idempotent and non-interactive.
# Fail-soft: a fresh host may not have the mise global installed yet.
home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  GITNEXUS_BIN="${config.home.homeDirectory}/.local/share/mise/installs/npm-gitnexus/latest/bin/gitnexus"
  if [ -x "$GITNEXUS_BIN" ]; then
    "$GITNEXUS_BIN" setup -c claude || true
  fi
'';
```

The `-c claude` token is verified against `SUPPORTED_CODING_AGENTS` in gitnexus 1.6.9 (valid set: `claude`, `cursor`, `opencode`, `codex`).

- [ ] **Step 3: Verify the flake evaluates.**

Run: `darwin-rebuild build --flake .#$(hostname -s) 2>&1 | tail -5`
Expected: evaluation succeeds; no error referencing `home.activation.gitnexusSetup`.

- [ ] **Step 4: Verify idempotency.** Run the activation twice (`darwin-rebuild switch` twice, or invoke `gitnexus setup -c claude` twice).
Expected: second run makes no destructive change; `~/.claude/skills/gitnexus-*` and `~/.claude/hooks/gitnexus/` still present; `settings.json` still valid JSON.

- [ ] **Step 5: Commit.**

```bash
git add home/cli/claude/default.nix
git commit -m "feat(gitnexus): nix-manage skills/hooks/MCP via setup activation (#<ticket>)"
```

---

## Task 2: `registry.ts` — locked, atomic registry access

**Why:** `~/.gitnexus/registry.json` is a single file every repo in the sweep wants to write, and the sweep is concurrent. This is a lost-update race. It must be closed **before** anything writes the registry.

**Files:**
- Create: `scripts/repomix-pack/src/registry.ts`, `src/registry.test.ts`

**Interfaces:**
- Produces:

```ts
export interface RegistryEntry {
  name: string; path: string; storagePath: string;
  lastCommit?: string; remoteUrl?: string; indexedAt?: string;
  stats?: Record<string, number>;
}
export function readRegistry(): Promise<RegistryEntry[]>;
/** Mutate under an exclusive lock; writes via temp-file + rename(2). */
export function updateRegistry(fn: (entries: RegistryEntry[]) => RegistryEntry[]): Promise<void>;
```

- Consumed by Task 3 (`graph.ts`) and Task 6 (prune).

- [ ] **Step 1: Write the failing tests first** (TDD — see superpowers:test-driven-development):
  - reads a well-formed registry;
  - a **missing** registry file yields `[]`, not a throw (fresh host);
  - a **corrupt/truncated** registry is surfaced as a clear error, never silently overwritten;
  - `updateRegistry` writes atomically — a killed write must not leave a truncated file;
  - **concurrency:** N concurrent `updateRegistry` calls each appending one entry all land (this test must **fail** without the lock — that failure is the point).

- [ ] **Step 2: Implement** with an exclusive lockfile and temp-write + `rename(2)`.

- [ ] **Step 3: Run tests.**

Run: `cd scripts/repomix-pack && bun test src/registry.test.ts`
Expected: all pass, including the concurrent-append test.

- [ ] **Step 4: Commit.**

---

## Task 3: `graph.ts` — commit gate, analyze, re-anchor

**Files:**
- Create: `scripts/repomix-pack/src/graph.ts`, `src/graph.test.ts`

**Interfaces:**
- Consumes: `RepoTarget` (Task 4), `registry.ts` (Task 2).
- Produces: `export async function refreshGraph(target: RepoTarget, cachePath: string): Promise<GraphResult>` where `GraphResult = { status: "analyzed" | "skipped" | "failed"; nodes?: number; bytes?: number; error?: string }`.

- [ ] **Step 1: Commit gate.** Skip `analyze` when the registry entry's `lastCommit` equals the origin HEAD of the cache checkout. Mirrors the pack's content-hash gate. Test both branches.

- [ ] **Step 2: Invoke `analyze`.** Command:

```
gitnexus analyze --no-stats --skip-skills --name <alias> <cache-path>
```

**Do not run this from inside the cache checkout** — mise refuses to execute in an untrusted config dir and the checkout carries the repo's own `mise.toml` (this is a confirmed blocker, not a hypothetical). Invoke from a neutral cwd, passing the checkout as the path argument.

> **UNVERIFIED, verify here:** it is not proven that gitnexus does not internally `chdir` into the target path, which would re-trigger the mise trust failure. **Verify option 1 works; if it does not, fall back** to invoking the binary by absolute path from the mise install prefix (same resolution as Task 1, Step 1). Record which option was used in the sub-issue.

- [ ] **Step 3: Re-anchor.** After a successful analyze, update the registry entry via `updateRegistry`:
  - `path` → the **dev clone** (`target.devClonePath`);
  - `storagePath` → stays in the cache (`<cache>/.gitnexus`);
  - and rewrite `repoPath` in `<cache>/.gitnexus/meta.json` **and** `gitnexus.json`.

  If `devClonePath` does not exist on this machine, **skip the re-anchor** and leave the entry anchored at the cache. Not an error — the graph stays queryable; only the working-tree tools are moot.

- [ ] **Step 4: Failure handling.** On analyze timeout or non-zero exit, **remove the registry entry** rather than leave a half-written LadybugDB registered. A corrupt-but-registered graph is worse than no graph. Return `{status: "failed"}`; never throw into the sweep.

- [ ] **Step 5: Tests.** Gate hit/miss; re-anchor rewrites all three locations (registry + `meta.json` + `gitnexus.json`); missing dev clone skips re-anchor without error; failed analyze deregisters. Mock the gitnexus binary.

- [ ] **Step 6: Commit.**

---

## Task 4: Config — `graph` opt-out + dev-clone path

**Files:**
- Modify: `scripts/repomix-pack/src/types.ts`, `src/config.ts`, `src/config.test.ts`, `modules/repomix/repos.toml`

- [ ] **Step 1: Extend `RepoTarget`** with `graph: boolean` (default `true`) and `devClonePath: string` (derived from the group's existing `base_dir` + repo name, with `~` expanded).

- [ ] **Step 2: Parse the per-repo `graph = false` opt-out** from the existing `[repo."owner/name"]` override tables. Default `true` when absent.

- [ ] **Step 3: Tests.** Default is `true`; explicit `false` is honored; `devClonePath` expands `~` and composes `base_dir` + name correctly for both the `personal` and `work` groups.

- [ ] **Step 4: Commit.**

---

## Task 5: Generalize the PR gate

**Why:** today the PR fires when the **pack's** content hash changes. Once the graph stage can also modify `CLAUDE.md`, a graph-only refresh would be **silently dropped**. This is the subtlest correctness risk in the phase.

**Files:**
- Modify: `scripts/repomix-pack/src/git-pr.ts`, `src/git-pr.test.ts`

- [ ] **Step 1: Write the regression test first** — it must fail against current `main`: pack unchanged + `CLAUDE.md` changed ⇒ a PR is still created/updated.

- [ ] **Step 2: Replace the pack-hash gate with "any staged diff against base."** Stage `CLAUDE.md` and `AGENTS.md` in addition to the pack and the `.gitignore` fix. Preserve the existing no-op behavior when **nothing** changed (no empty PRs, no Slack spam — a phase 1 invariant).

- [ ] **Step 3: Tests.** Pack-only change → PR. Graph-only change → PR. Both → one PR. Neither → **no** PR, no notification.

- [ ] **Step 4: Commit.**

---

## Task 6: Orchestration + CLI + disk budget

**Files:**
- Modify: `scripts/repomix-pack/src/index.ts`, `src/index.test.ts`

- [ ] **Step 1: Wire the graph stage** into the per-repo flow, after checkout and before the PR step, so its `CLAUDE.md` edit is staged by Task 5's gate.

- [ ] **Step 2: Run the graph stage SERIALLY.** The pack stage keeps its bounded parallel pool; `analyze` spawns its own worker pool (`cores-1`), so concurrent analyses would thrash the machine. Serialize graph work even while packs run in parallel.

- [ ] **Step 3: CLI flags.** Add `--graph-only` and `--no-graph`, composing with the existing `--group`/`--only`/`--dry-run`/`--no-pr`/`--no-notify`.

- [ ] **Step 4: Disk budget + prune.** Log total graph cache size per sweep (full coverage is projected at **~1–2 GB**; measured: `moneta` 41 MB, `olympus-sdk` 318 MB). Prune graphs + registry entries for repos no longer in `repos.toml`.

- [ ] **Step 5: End-of-run summary.** Extend the existing summary table with a graph column (`analyzed | skipped | failed`) and the total cache size. Per-repo isolation is preserved: a graph failure must never abort the sweep.

- [ ] **Step 6: Tests + commit.**

---

## Task 7: Integration test + single-repo pilot

**Files:**
- Create: `scripts/repomix-pack/src/graph.integration.test.ts`

- [ ] **Step 1: Integration test** against a sandbox repo, asserting the properties the spike established:
  1. analyze → re-anchor → `detect-changes` reads the **dev clone**, not the cache;
  2. the dev clone stays free of `.gitnexus` **and** of injected files;
  3. a **graph-only** change still opens a PR (the Task 5 regression, end-to-end);
  4. an unchanged repo no-ops — no analyze, no PR.

- [ ] **Step 2: Pilot on ONE personal repo** (suggest `moneta` — already spiked, 14s/41 MB, so deviation from the known-good baseline is obvious).

Run: `repomix-pack --only nwlnexus/moneta --graph-only`
Expected: graph analyzed; registry `path` → `~/projects/personal/moneta`, `storagePath` → cache; **no `.gitnexus` in the dev clone**; `gitnexus query -r moneta` works from an unrelated cwd.

- [ ] **Step 3: Verify against the real dev clone.** Confirm `git status` in `~/projects/personal/moneta` shows **no** new untracked/modified files from the sweep.

- [ ] **Step 4: Commit.**

---

## Task 8: Fan-out — personal group, then work

- [ ] **Step 1: Personal group.** `repomix-pack --group personal`. Confirm all 9 repos land a graph. Record actual wall-time and disk against the ~1–2 GB projection — **if it materially overshoots, stop and reassess** rather than filling the disk.

- [ ] **Step 2: Work group.** `repomix-pack --group work` — `marquee` and `drop-app`, the two most stale graphs (last indexed 2026-05-23 and 2026-05-25). These are the largest freshness wins in the phase.

- [ ] **Step 3: Confirm the scheduled sweep** picks up the graph stage (launchd agent from phase 1 Task 12; no new scheduler).

- [ ] **Step 4: Update the spec's status** and close the epic.

---

## Deferred Project 2 seams (tracked, NOT in this plan)

These are the remaining Project 2 questions. They are **not brainstormed** — each carries the `needs-brainstorm` label and must get a design session before it is planned or built. They are filed so they are not lost, not so they are silently implemented.

| Seam | Issue | Sequencing |
| --- | --- | --- |
| The brain destination — where packs + graph actually flow | [#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39) | Settle "what question does the brain answer that moneta + gitnexus + Obsidian can't?" **first** — it may collapse the seam entirely. |
| openwiki — adopt or reject? | [#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40) | A decision spike, not a build. Blocks #39. |
| mnemosyne / Obsidian / moneta — replace, retire, or re-layer? | [#41](https://github.com/nwlnexus/nix-darwin-hm/issues/41) | **Do not brainstorm first.** This should *fall out of* #39 and #40, not precede them. |

---

## Self-Review Notes

- **`--skip-skills` has a hard ordering dependency on Task 1.** Using it before the skills are nix-managed would leave a fresh host with no gitnexus skills at all. Task 1 is in Group A for this reason.
- **The Task 5 gate change is the one place a naive implementation silently loses data.** Its regression test is written first, deliberately.
- **The mise-trust workaround in Task 3 Step 2 is unverified.** It carries an explicit fallback; the executing worker must record which path was taken.
- **A graph built from `origin/main` will not contain feature-branch-only symbols**, so `detect-changes` cannot map a brand-new function (confirmed in the spike). Accepted; `--branch` is the escape hatch if it bites.
