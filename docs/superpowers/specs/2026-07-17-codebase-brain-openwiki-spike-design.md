# Codebase Brain — OpenWiki Spike Design

**Date:** 2026-07-17  
**Status:** Accepted — **Path O adopted** (see [results](2026-07-17-codebase-brain-openwiki-spike-results.md); parent updated)  
**Parent:** [2026-07-15-codebase-brain-pipeline-design.md](2026-07-15-codebase-brain-pipeline-design.md)  
**Related:** [#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39) (brain destination),
[#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40) (openwiki — adopt as Layer 1 narrative /
code mode only; personal mode still rejected)

---

## 1. Why this spike

The July 15 brain pipeline rejected openwiki as the wiki engine and planned a custom
facet → Ollama slot-fill → MDX path alongside repomix, gitnexus, syft, Moneta, and Astro.

A design review challenged that rejection. The important distinction:

| Tool | Answers | Spike role |
| --- | --- | --- |
| **repomix** | Whole-repo LLM corpus | Layer 1 producer (shared) |
| **openwiki code mode** | Narrative multi-file wiki + OKF frontmatter | Layer 1 candidate doc producer (Path O) |
| **gitnexus** | Structural how / blast radius | Session-native graph; Job publishes refs to R2 |
| **custom slotted MDX** | Constrained overview / inventory / clusters | Path C — July 15 baseline |
| **syft** | Dependency truth (CycloneDX) | Shared producer (never LLM-authored) |

**openwiki cannot replace gitnexus.** The open question is whether openwiki code mode + OKF can
replace (or complement) the *custom narrative doc-generation layer*.

This spike validates that before rewriting the full pipeline.

---

## 2. Goals / non-goals

### Goals

- Run Path O and Path C side-by-side on **moneta** (single service) and **olympus-sdk** (monorepo).
- Keep **local / on-prem Job compute** for clone + tool runs (not “OpenWiki hosted elsewhere”).
- Drive **Path O (openwiki)** with **Anthropic** (native OpenWiki provider path).
- Drive **Path C (custom slots)** with **Mac Studio Ollama** (July 15 baseline unchanged for that path).
- Prove a Job image where **repomix**, **gitnexus**, and **openwiki** are installed and callable.
- Produce throwaway artifacts + **dry-run Moneta nugget JSON** (no production writes).
- Score both paths on coverage, monorepo shape, determinism, frontmatter/OKF fit, Moneta fit,
  cost/ops, and update friendliness — with LLM asymmetry called out in scorecards.
- Emit a recommendation: adopt Path O, keep Path C, or hybrid — and list concrete July 15 spec
  edits if openwiki wins.

### Non-goals

- Argo Events/Workflows production cutover, brain PRs, shared GitNexus Containers, launchd cutover.
- Writing to production Moneta.
- Committing generated docs into source repos.
- openwiki **personal** mode (Gmail/Notion/HN multi-source brain — still rejected).
- Shipping a production Astro site from this spike (optional throwaway content folder only if
  files already look Astro-ready).
- Proving full idempotency / supersede semantics for Moneta.
- Building the full Moneta/mnemosyne “pull graph detail on demand” path in this spike (design only;
  see §4.2).

---

## 3. Decisions locked before the spike

| Decision | Choice |
| --- | --- |
| Comparison method | Spike both paths (C from the design review options) |
| Repos | `moneta` + `olympus-sdk` |
| Where work runs | **Local / on-prem Job compute** — container (or bare-metal stand-in) runs the tools |
| Job tooling | Image (or PATH) must expose **`repomix`**, **`gitnexus`**, **`openwiki`** as callable CLIs |
| Producer layering | **Layer 1:** repomix + openwiki (candidate). **GitNexus:** session-local + R2; **shared MCP canonical** (parent C) |
| Graph consumer (parent) | **C** locked: shared GitNexus MCP canonical; mnemosyne convenience later on same refs; Moneta = refs only |
| Outputs | Side-by-side artifacts + dry-run Moneta nugget JSON (**B**) |
| Path O LLM | **Anthropic** via OpenWiki’s native provider (not Studio Ollama) |
| Path C LLM | Studio Ollama (July 15 slotted-prose baseline) |
| Preferred Anthropic model | OpenWiki default / onboarding model unless a cheaper model is clearly adequate |
| Preferred Ollama model (Path C) | `qwen3.6:27b-mlx` with smaller instruct fallback on timeout |

**Callout — local compute + Anthropic:** generation still happens on our Job (clone, pack, analyze,
openwiki CLI). We are **not** outsourcing the pipeline to a remote wiki host. OpenWiki’s LLM
backend for Path O is Anthropic; the Job is the worker.

**Asymmetry is intentional for the spike:** Path O quality/cost reflects Anthropic + openwiki;
Path C reflects Studio Ollama + custom slots. Scorecards must separate “tool shape” from “model
family” so the adopt/reject decision is not confused with “Anthropic vs Ollama.”

---

## 4. Architecture of the spike

```text
Job container (local / on-prem) — tools on PATH:
  repomix | gitnexus | openwiki | syft

throwaway workspace
  clone moneta | olympus-sdk
       |
       +-- Layer 1:
       |     repomix pack
       |     Path O: openwiki code (--init / --update --print) → Anthropic → OKF markdown
       |
       +-- GitNexus (Job runs analyze; product intent = session-native):
       |     gitnexus analyze → graph artifact
       |     record R2-style ref metadata (owner/repo/sha/digest/uri sketch)
       |
       +-- syft → sbom.cdx.json
       |
       +-- Path C: thin custom slotted docs (overview + syft inventory
                   + optional gitnexus cluster pages) via Studio Ollama
       |
       +-- dry-run Moneta nuggets (both paths) → JSON only
       +-- per-repo scorecard → scorecard-summary.md
```

### 4.1 Mental model

| Store / artifact | Role in spike |
| --- | --- |
| Pack (repomix) | Layer 1 corpus ground truth |
| Path O wiki (openwiki + Anthropic) | Candidate narrative docs (OKF) |
| Path C MDX/MD | Baseline constrained docs (Studio Ollama) |
| GitNexus graph | Structural truth; session-local when present |
| Shared GitNexus MCP | **Canonical** non-cwd structural path (parent contract C; out of spike scope) |
| R2 graph ref (sketch) | Pointer + digests for MCP hydration + Moneta metadata |
| Dry-run Moneta JSON | Judge recall shape without polluting memory; refs only |
| Scorecards | Decision packet |

### 4.2 Layering (locked intent)

**Layer 1 — pack + narrative docs**

- **repomix** and **openwiki** are the primary Job-facing producers for “what is this repo?” corpus
  and narrative wiki.
- If Path O wins, July 15’s custom slotted MDX layer is replaced (or hybridized) by openwiki OKF;
  repomix stays.

**GitNexus — session when local, shared MCP canonical, R2 refs for hydration**

- The graph is structural truth for **in-session** use (local index when present).
- **Canonical** cross-repo / non-cwd path: **shared GitNexus MCP** hydrated from R2 (parent
  contract **C**, locked 2026-07-17).
- The Job still runs `gitnexus analyze` so freshness is push-driven and we publish a
  **reference** (and tarball) to R2: e.g. `graphs/{owner}/{repo}/{sha}` + `latest`,
  plus digests in frontmatter / dry-run Moneta metadata (`graphDigest`, `graphUri`).
- Moneta stores **refs only** — never graph bodies, never answers `impact`/`query`.
- **Later (post-spike / parent phase 5):** mnemosyne may use those refs to **hint or wake the
  same shared MCP** when a bit of work needs blast-radius — convenience on the same contract,
  not a second graph product. SessionStart stays episodic; no auto-inject of graphs or
  codebase docs.

This spike records the ref shape and digests; it does **not** implement shared MCP serve or
mnemosyne convenience.

### 4.3 Job container requirements

The Job image (spike: Docker/OrbStack/Apple Container or a documented bare-metal PATH stand-in)
must install and expose:

| Binary | Layer | Spike use |
| --- | --- | --- |
| `repomix` | 1 | Pack |
| `openwiki` | 1 | Path O narrative |
| `gitnexus` | session / R2 | Analyze + graph artifact + ref metadata |
| `syft` | shared | SBOM (unchanged) |

Secrets for the spike: Anthropic API key for Path O; Studio Ollama URL reachable for Path C.
No production Moneta token required (dry-run JSON only).

---

## 5. Workspace layout

```text
/tmp/codebase-brain-openwiki-spike/
  repos/
    moneta/
    olympus-sdk/
  artifacts/
    moneta/
      repomix.xml
      graph/                    # gitnexus output / facets as available
      graph-ref.json            # R2-style pointer sketch (uri, sha, digests)
      sbom.cdx.json
      openwiki-okf/             # Path O (Anthropic)
      custom-mdx/               # Path C (Studio Ollama)
      moneta-dry-run.openwiki.json
      moneta-dry-run.custom.json
      scorecard.md
    olympus-sdk/
      ... (same shape)
  scorecard-summary.md
```

**Guardrails**

- Target repos stay untouched except as cloned copies under `repos/`.
- No generated `openwiki/`, `CLAUDE.md`, or `AGENTS.md` edits land in working clones we care about;
  copy Path O output into `artifacts/<repo>/openwiki-okf/` and record raw vs normalized differences.
- Code mode only — never `openwiki personal`.
- Graph blobs may be large; spike may keep analyze output local and only write **ref + digest**
  JSON that mirrors the future R2 contract.

---

## 6. Run sequence (per repo)

1. Clone default branch into throwaway `repos/<name>/`.
2. **Layer 1:** Repomix → `artifacts/<name>/repomix.xml`.
3. `gitnexus analyze` → graph/facets under `artifacts/<name>/graph/`; write `graph-ref.json`
   (owner, repo, sha, graphDigest, illustrative `r2Uri`).
4. Syft → `artifacts/<name>/sbom.cdx.json`.
5. **Path O:** configure OpenWiki → **Anthropic**; run
   `openwiki code --update --print` (init if needed); copy OKF output to `openwiki-okf/`.
6. **Path C:** generate thin custom docs via **Studio Ollama**:
   - `overview` (facet + pack excerpts, slotted prose)
   - `tech-inventory` from syft only (no LLM dependency rows)
   - optional 1–2 `cluster-*` pages from gitnexus facets if cheap
7. Dry-run Moneta: heading-sized nuggets for both paths with illustrative tags/metadata
   (`kind:codebase_doc`, `repo:`, digests, `idempotencyKey`, `brainPath`, `graphDigest` /
   `graphUri`). Write JSON only — **no graph payloads in nugget content**.
8. Fill `scorecard.md` for the repo.

After both repos: write `scorecard-summary.md` with recommendation and proposed parent-spec edits.

---

## 7. Comparison rubric

Same rubric for both repos:

| Dimension | What “good” looks like |
| --- | --- |
| Coverage | Humans + agents can answer “what is this?” and “where is X?” |
| Monorepo shape | `olympus-sdk` packages are discoverable (pages/sections), not one flat blob |
| Determinism | Inventory/deps match syft; no invented packages |
| Frontmatter | OKF base usable; nwl extensions (`repo`, `sha`, digests, `docType`, graph ref) fit |
| Moneta fit | Heading-sized nuggets look recall-worthy; provenance + **graph ref** populate cleanly |
| Cost/ops | Path O: Anthropic latency/tokens/$ + openwiki CLI; Path C: Studio Ollama quirks; Job image size |
| Diff friendliness | Incremental `--update` behavior vs full regen |
| Layering fit | Layer 1 docs useful without loading the graph; graph refs sufficient for later on-demand pull |

**Allowed decision outcomes**

1. **Adopt Path O** as Layer 1 narrative producer; keep repomix; keep gitnexus as session + R2 refs.
2. **Keep Path C** (July 15 status quo); use OKF as format inspiration only.
3. **Hybrid** — e.g. openwiki for overview/architecture; custom for inventory; gitnexus facets for
   cluster pages when openwiki flattens packages badly.

---

## 8. Frontmatter / Moneta contracts (spike)

### OKF base (Path O)

OpenWiki 0.2 OKF-style YAML frontmatter is the base layer, e.g.:

```yaml
---
type: Repository Overview
title: moneta — Architecture
description: Cloudflare Worker memory backend with D1 + Vectorize
tags: [cloudflare, workers, memory]
timestamp: 2026-07-17T12:00:00Z
---
```

### Nwl extensions (pipeline-owned; may be post-normalized in spike)

```yaml
docType: overview          # overview | inventory | cluster | …
repo: moneta
owner: nwlnexus
slug: moneta/overview
source:
  sha: …
  packHash: sha256:…
  graphDigest: sha256:…
  graphUri: r2://graphs/nwlnexus/moneta/<sha>   # ref only; not the graph body
  templateVersion: openwiki-0.2   # or custom-spike-1
brainPath: docs/codebases/moneta/overview.md
status: generated
```

### Dry-run Moneta nugget (illustrative)

Same shape as the parent spec: short `content`, tags including `kind:codebase_doc` and `repo:`,
provenance in `metadata` (`sha`, `slug`, `brainPath`, digests, `idempotencyKey`, **`graphDigest` /
`graphUri`**). No `/capture` calls during the spike. Nuggets must not embed graph dumps —
refs only, so future mnemosyne can fetch detail when a task needs it.

### `graph-ref.json` (illustrative)

```json
{
  "owner": "nwlnexus",
  "repo": "moneta",
  "sha": "…",
  "graphDigest": "sha256:…",
  "r2Uri": "r2://graphs/nwlnexus/moneta/…",
  "latestUri": "r2://graphs/nwlnexus/moneta/latest",
  "intent": "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later"
}
```

---

## 9. Parent-spec changes if Path O wins

### Keep unchanged

- Push → Argo Job orchestration (local / on-prem compute)
- repomix pack (Layer 1)
- gitnexus analyze in Job + R2 graph publish; **shared GitNexus MCP canonical** (parent contract C)
- syft SBOM as deterministic inventory truth
- Moneta as recall sink (`kind:codebase_doc`) with **graph refs only**
- Astro central brain as human docs site
- Publish order: R2 → Moneta → brain PR
- No SessionStart auto-inject of codebase docs or graphs
- GitNexus as structural how / blast radius (not replaceable by openwiki prose)
- mnemosyne convenience later hints/wakes the **same** MCP from Moneta refs (never serves the graph)

### Change

| July 15 | If openwiki wins |
| --- | --- |
| Custom facet → Ollama slot-fill → hand-rolled MDX templates | **openwiki code mode** (Anthropic) produces narrative OKF markdown |
| Custom Zod frontmatter from scratch | **OKF base** + nwl extensions validated by Zod |
| Custom templates for overview / inventory / cluster-* | **openwiki owns narrative**; **syft owns inventory**; clusters from openwiki taxonomy and/or thin gitnexus supplements |
| Reject openwiki (#40) | **Adopt as Layer 1 doc producer** (not as gitnexus replacement) |
| Ollama only for slotted prose | **Anthropic via openwiki** for narrative; Ollama optional only for remaining custom glue |
| Job image: repomix + gitnexus + syft + custom | Job image: **repomix + openwiki + gitnexus + syft** (all callable) |
| Shared GitNexus as always-on deep dive | **Shared MCP canonical** (hydrate from R2); session-local when present; mnemosyne convenience later on same refs; Moneta = refs only |

### Hybrid fallback

If monorepo quality is uneven: openwiki for overview/architecture; always custom syft inventory;
gitnexus facet cluster pages only when openwiki flattens packages.

### What this spike alone will not claim

- Full Argo readiness
- Production Moneta supersede semantics
- Shared GitNexus Container readiness
- Implemented Moneta/mnemosyne on-demand graph fetch (design intent only)

---

## 10. Success criteria for the spike

- Both repos produce Path O and Path C artifacts under `/tmp/codebase-brain-openwiki-spike/`.
- Job stand-in proves `repomix`, `gitnexus`, and `openwiki` are callable in one environment.
- `graph-ref.json` exists per repo (R2 pointer sketch + digests).
- Dry-run Moneta JSON exists for both paths on both repos (refs in metadata, no graph bodies).
- Scorecards + `scorecard-summary.md` recommend adopt / keep / hybrid with evidence, and call out
  Anthropic vs Ollama asymmetry explicitly.
- Explicit notes on: Anthropic + openwiki reliability; OKF → Astro adapter effort;
  `olympus-sdk` package discoverability; Layer 1 vs session-graph layering.
- Parent design ([2026-07-15](2026-07-15-codebase-brain-pipeline-design.md)) and #40 are updated
  **after** Path O acceptance (done 2026-07-17).

---

## 11. Open implementation choices (not blocking design approval)

1. Exact Anthropic model id for Path O (OpenWiki default vs pinned cheaper model).
2. Exact Studio Ollama host/URL on the tailnet for Path C.
3. Whether the spike Job is a real container image build or a documented bare-metal PATH +
   `which` checklist that the future image must satisfy.
4. Whether Path C is a minimal Bun/TS script in the spike workspace or ad-hoc prompts with a
   fixed template skeleton.
5. Whether gitnexus facets are exported via existing CLI output or a small extract script.
6. Whether to keep spike artifacts only under `/tmp` or also copy the decision packet into
   `docs/superpowers/` after review.
7. Exact R2 key layout / signed URL shape for later mnemosyne on-demand graph pull (parent spec
   already sketches `graphs/{owner}/{repo}/{sha}.tgz` — spike only needs a compatible ref JSON).

