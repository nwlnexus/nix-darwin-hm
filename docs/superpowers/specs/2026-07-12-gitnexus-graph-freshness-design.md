# GitNexus Graph Freshness — Design Spec

**Date:** 2026-07-12
**Status:** Approved for planning
**Scope:** Phase 2 of the repomix/brain work. Closes seam (b) and (c) of
[the repomix pipeline spec](2026-07-12-repomix-pipeline-design.md) §7: gitnexus index freshness,
shared graph state, and the "same trigger also refreshes the graph" synergy.

**Explicitly NOT in this spec:** the brain *destination* (where packs + graph ultimately flow),
the openwiki adopt/reject decision, and any mnemosyne/Obsidian/moneta re-architecture. Those
remain Project 2's other seams and get their own spec.

---

## 1. Problem

Phase 1 gave every repo an always-current repomix pack. The gitnexus code graph got nothing, and
it is in worse shape than "stale":

| Symptom | Measured (2026-07-12) |
| --- | --- |
| **Coverage** | 3 of 11 configured repos indexed. `nix-darwin-hm`, `moneta`, and six others have **no graph at all**. |
| **Freshness** | `marquee` last indexed 2026-05-23, `drop-app` 2026-05-25. Nothing re-analyzes on change. |
| **Reproducibility** | gitnexus's skills, hooks, and MCP registration are **machine-local**, written once by an imperative `gitnexus setup`. A fresh nix-darwin host gets the binary and none of the integration. |

Coverage is the real gap; freshness is the visible symptom. Reproducibility is a latent bug that
exists today independent of this work.

The naive fix — "add `gitnexus analyze` to the sweep" — collides head-on with phase 1's central
discipline: **the pipeline never touches a dev working clone.** gitnexus stores its graph *inside*
the repo (`<repo>/.gitnexus`), and `~/.gitnexus/registry.json` points MCP at those paths.

## 2. Spike findings (empirical, not inferred)

A throwaway spike against `moneta` (unindexed, so no existing graph was at risk; `registry.json`
backed up and restored) settled the design. **Every claim below was executed, not reasoned:**

1. **Repo resolution is 100% registry/name-based. There is no cwd fallback.** Any tool invoked
   without `-r` fails with `Multiple repositories indexed. Specify which one`. This is what makes
   a graph stored outside its repo viable at all.
2. **The graph is relocatable.** Node paths inside the 205 MB LadybugDB are stored *repo-relative*
   (`packages/hermes/src/index.ts`). Across the whole binary there are **2** absolute-path hits,
   against a single `repoPath` anchor in `meta.json`. The graph is a rooted tree plus one pointer.
3. **Re-anchoring works, including for the working-tree tools.** With storage left in the cache and
   the registry `path` + `meta.repoPath` pointed at a dev clone, `query`/`context`/`impact`/`cypher`
   all work, and **`detect-changes` correctly read the dev clone's working tree** — it caught a
   mutation to `derivePattern` and mapped it to 6 affected execution flows at "high" risk.
4. **`rename` is safe under re-anchoring.** It has no CLI surface (MCP-only), so it was verified by
   source inspection: working-tree ops resolve through `entry.path` via `resolveWorktreeCwd`. With
   the entry anchored at the dev clone, `rename` writes to the dev clone, **not** the cache.
5. **`--index-only` injects nothing.** `git status` stayed clean in the analyzed checkout.
   `--no-stats` omits precisely the volatile symbol counts that cause marked-section churn.
6. **`.gitnexus/` self-ignores** — its `.gitignore` is literally `*`. The graph can never be committed.
7. **Cost:** `moneta` (106 files) → **14s, 41 MB**. Against `olympus-sdk` (655 files → 318 MB),
   full 11-repo coverage extrapolates to **~1–2 GB of cache**.
8. **BLOCKER — mise trust.** The cache checkout carries the repo's own `mise.toml`. Running gitnexus
   through the mise shim *from inside* that checkout dies: `Config files in ... are not trusted`.
   Phase 1 never hit this because `repomix-pack` execs `bun` straight from nix.

### Known limitation, accepted

A graph built from `origin/main` does not contain symbols that exist only on a feature branch, so
`detect-changes` will not map a brand-new function (confirmed in the spike: appending a new function
yields "No changes detected", because it maps to no indexed symbol). This is the price of not
indexing WIP. gitnexus's `--branch` flag is the escape hatch if it ever bites.

## 3. Architecture

Extend the existing `repomix-pack` runner with a **graph stage**. One sweep, two artifacts. No new
pipeline, no second scheduler.

Per repo, after phase 1's existing clean-checkout step:

1. **Gate** — compare origin HEAD against the graph's `lastCommit` in `registry.json`.
   Equal → skip analyze. (Mirrors the pack's content-hash gate.)
2. **Analyze** — `gitnexus analyze --no-stats --skip-skills --name <alias> <cache-path>`.
   Storage lands in `<cache>/.gitnexus` (gitignored, never committed). The **stable**
   `<!-- gitnexus:start -->` section is written into the cache checkout's `CLAUDE.md`/`AGENTS.md`.
3. **Re-anchor** — rewrite the registry entry's `path` (and `meta.repoPath`) to the **dev clone**;
   `storagePath` stays in cache. If the repo is not cloned on this machine, leave it anchored at the
   cache: still queryable, and the working-tree tools are moot rather than broken.
4. **PR** — the refreshed `CLAUDE.md` section is already a modified file in the cache checkout, so it
   rides the existing `automation/repomix-pack` commit beside the pack. One PR, one review.

**Net effect:** dev clones stay pristine (no 318 MB `.gitnexus`, no injected files), every repo gets a
graph, the graph reflects `origin/main`, and `detect-changes` still diffs the *live working tree*
against it — which is the question actually being asked ("what am I changing relative to main?").

### Why `--skip-skills`

gitnexus otherwise injects `.claude/skills/gitnexus/*` into every repo. Those skills belong to the
*machine*, not to eleven repos — see §6, which makes that true on every host rather than just this one.

## 4. Runner changes

New module `graph.ts`; new `registry.ts`. Changes to existing modules called out explicitly.

### 4.1 Registry is shared mutable state — serialize it

`~/.gitnexus/registry.json` is a single file that **every repo in the sweep wants to write**, and
phase 1 runs repos through a bounded parallel pool. This is a textbook lost-update race.

- Registry reads/writes go through `registry.ts` with an **exclusive lock + atomic replace**
  (write temp, `rename(2)`).
- The **graph stage runs serially**, even though the pack stage stays parallel: `analyze` spawns a
  worker pool sized to `cores-1`, so N concurrent analyses would thrash the machine.

### 4.2 The PR gate must be generalized

Today the PR fires when the **pack's** content hash changes. Now the `CLAUDE.md` section can change
while the pack does not (and vice versa). The gate becomes **"any staged diff against base."**

> Without this change a graph-only refresh is silently dropped. This is the one place a naive
> implementation quietly loses data.

`git-pr.ts` must stage `CLAUDE.md` and `AGENTS.md` in addition to the pack and the `.gitignore` fix.

### 4.3 Invocation must bypass the mise shim

Per finding 8. Two options, in order of preference:

1. Invoke `analyze` from a **neutral cwd**, passing the checkout as the path argument (the failure was
   cwd-triggered — mise parsed the checkout's `mise.toml` because we were standing in it).
2. **Fallback:** invoke gitnexus by absolute path from its mise install prefix.

Option 1 is tidier but **unverified** — gitnexus may internally `chdir`. The implementation must
verify option 1 and fall back to option 2 without ceremony.

### 4.4 Config

`repos.toml` gains an optional per-repo `graph = false` opt-out. The dev-clone path is derived from
the group's existing `base_dir` + repo name; if that path does not exist, skip re-anchoring and leave
the entry anchored at the cache (§3, step 3).

### 4.5 CLI

`repomix-pack` gains `--graph-only` and `--no-graph`, composing with the existing flags.

## 5. Freshness model — a deliberate asymmetry

**The graph refreshes on the local sweep only, not in CI.** Phase 1's freshness guarantee is
CI-on-push, because only CI sees every commit. But the graph is a 41–318 MB local binary that CI has
nowhere to publish; shipping it to R2 and syncing it across machines was considered and **rejected as
disproportionate machinery**.

Concretely: **the pack is current within minutes of a push; the graph can be up to a day stale**
(bounded by the launchd sweep cadence). Each machine builds its own graph; nothing is transported.

This asymmetry is accepted, not overlooked. If a day-stale graph proves insufficient, the escape
hatches in preference order are: (a) shorten the sweep interval, (b) trigger a sweep from a git hook,
(c) revisit the publish-and-sync design.

## 6. Nix wiring — make the integration reproducible

This closes the reproducibility bug in §1, which exists **today**, independent of the graph work.

gitnexus's skills, hooks, and MCP registration are currently machine-local. The fix follows the
**precedent already in `home/cli/claude/default.nix`**, which manages `mem0ctl`/`mnemosyne` via a
fail-soft imperative merge:

```nix
home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  "${gitnexusBin}" setup -c claude || true
'';
```

`gitnexus setup` is idempotent and non-interactive (`-c/--coding-agent`), so it drops straight into an
activation entry — no need to vendor skill files into the nix store, and the skills track the
mise-pinned gitnexus version automatically.

The agent token is `claude` (verified against `SUPPORTED_CODING_AGENTS` in gitnexus 1.6.9; the full
set is `claude`, `cursor`, `opencode`, `codex`).

## 7. Error handling

- **Per-repo isolation** carries over from phase 1 — one repo's analyze failure never aborts the sweep.
- **Analyze timeout/crash → remove the registry entry** rather than leave a half-written LadybugDB
  registered. gitnexus's own docs warn about DB corruption on interrupted analyze; a corrupt-but-
  registered graph is worse than no graph.
- **Registry corruption** guarded by atomic replace (§4.1).
- **Disk** logged per sweep (full coverage is ~1–2 GB). A prune of graphs for repos dropped from
  `repos.toml` is in scope.
- **Missing dev clone** → skip re-anchor, leave anchored at cache. Not an error.

## 8. Testing

- **Unit** (`bun test`): the commit gate; the re-anchor rewrite; serialized/atomic registry writes
  (including a concurrent-write test that would fail without the lock); the generalized PR gate.
- **Integration**, against a sandbox repo, asserting the properties the spike established:
  1. analyze → re-anchor → `detect-changes` reads the **dev clone**, not the cache;
  2. the dev clone remains free of `.gitnexus` and of injected files;
  3. a **graph-only** change (pack unchanged) still opens a PR — the §4.2 regression test;
  4. an unchanged repo no-ops (no analyze, no PR).

## 9. Rollout

1. Nix: gitnexus agent integration via activation (§6) — independently valuable, ship first.
2. `registry.ts` + `graph.ts` behind `--graph-only`, piloted on **one** personal repo.
3. Generalize the PR gate (§4.2) + stage `CLAUDE.md`/`AGENTS.md`.
4. Fan out to the `personal` group; confirm disk and wall-time against the ~1–2 GB estimate.
5. `work` group (`marquee`, `drop-app`) — the two most stale graphs.

## 10. Out of scope (remaining Project 2 seams)

Filed and labelled `needs-brainstorm`. Each requires a design session before it is planned or built:

- **[#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39)** — the brain destination: where packs + the graph ultimately flow.
- **[#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40)** — openwiki: adopt or reject.
- **[#41](https://github.com/nwlnexus/nix-darwin-hm/issues/41)** — mnemosyne / Obsidian / moneta: replace, retire, or re-layer. Should *fall out of* #39 and #40 rather than precede them.
