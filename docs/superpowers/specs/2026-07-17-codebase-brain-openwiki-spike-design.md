# Codebase Brain — OpenWiki Spike Design

**Date:** 2026-07-17  
**Status:** Draft for review  
**Parent:** [2026-07-15-codebase-brain-pipeline-design.md](2026-07-15-codebase-brain-pipeline-design.md)  
**Related:** [#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39) (brain destination),
[#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40) (openwiki adopt/reject — reopen or
comment after spike recommendation; do not flip the parent reject until evidence lands)

---

## 1. Why this spike

The July 15 brain pipeline rejected openwiki as the wiki engine and planned a custom
facet → Ollama slot-fill → MDX path alongside repomix, gitnexus, syft, Moneta, and Astro.

A design review challenged that rejection. The important distinction:

| Tool | Answers | Spike role |
| --- | --- | --- |
| **repomix** | Whole-repo LLM corpus | Shared producer |
| **gitnexus** | Structural how / blast radius | Shared producer (not replaceable by prose) |
| **openwiki code mode** | Narrative multi-file wiki + OKF frontmatter | Path O — candidate doc producer |
| **custom slotted MDX** | Constrained overview / inventory / clusters | Path C — July 15 baseline |
| **syft** | Dependency truth (CycloneDX) | Shared producer (never LLM-authored) |

**openwiki cannot replace gitnexus.** The open question is whether openwiki code mode + OKF can
replace (or complement) the *custom narrative doc-generation layer*.

This spike validates that before rewriting the full pipeline.

---

## 2. Goals / non-goals

### Goals

- Run Path O and Path C side-by-side on **moneta** (single service) and **olympus-sdk** (monorepo).
- Drive both LLM paths with **Mac Studio Ollama** over the tailnet (same model family as July 15).
- Produce throwaway artifacts + **dry-run Moneta nugget JSON** (no production writes).
- Score both paths on coverage, monorepo shape, determinism, frontmatter/OKF fit, Moneta fit,
  cost/ops, and update friendliness.
- Emit a recommendation: adopt Path O, keep Path C, or hybrid — and list concrete July 15 spec
  edits if openwiki wins.

### Non-goals

- Argo Events/Workflows, brain PRs, shared GitNexus Containers, launchd cutover.
- Writing to production Moneta.
- Committing generated docs into source repos.
- openwiki **personal** mode (Gmail/Notion/HN multi-source brain — still rejected).
- Shipping a production Astro site from this spike (optional throwaway content folder only if
  files already look Astro-ready).
- Proving full idempotency / supersede semantics for Moneta.

---

## 3. Decisions locked before the spike

| Decision | Choice |
| --- | --- |
| Comparison method | Spike both paths (C from the design review options) |
| Repos | `moneta` + `olympus-sdk` |
| Runtime | Least friction: bare metal first; Apple Container or OrbStack only if isolation is needed |
| Outputs | Side-by-side artifacts + dry-run Moneta nugget JSON (**B**) |
| LLM | Studio Ollama for both paths (**A**) |
| OpenWiki wiring | `OPENWIKI_PROVIDER=openai-compatible` → Studio `:11434/v1` (no native Ollama provider) |
| Preferred model | `qwen3.6:27b-mlx` with smaller instruct fallback on timeout |

**OpenWiki default (for awareness):** onboarding defaults to OpenAI (`gpt-5.6-terra`). We do **not**
use that default for this spike; we force Studio Ollama via openai-compatible so quality matches
production intent.

---

## 4. Architecture of the spike

```text
throwaway workspace
  clone moneta | olympus-sdk
       |
       +-- repomix pack
       +-- gitnexus analyze
       +-- syft → sbom.cdx.json
       |
       +-- Path O: openwiki code (--init / --update --print) → OKF markdown
       +-- Path C: thin custom slotted docs (overview + syft inventory
                   + optional gitnexus cluster pages)
       |
       +-- dry-run Moneta nuggets (both paths) → JSON only
       +-- per-repo scorecard → scorecard-summary.md
```

### Mental model

| Store / artifact | Role in spike |
| --- | --- |
| Pack + SBOM + graph | Shared ground truth |
| Path O wiki | Candidate narrative docs (OKF) |
| Path C MDX/MD | Baseline constrained docs |
| Dry-run Moneta JSON | Judge recall shape without polluting memory |
| Scorecards | Decision packet |

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
      sbom.cdx.json
      openwiki-okf/             # Path O
      custom-mdx/               # Path C
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

---

## 6. Run sequence (per repo)

1. Clone default branch into throwaway `repos/<name>/`.
2. Repomix → `artifacts/<name>/repomix.xml`.
3. `gitnexus analyze` → graph/facets under `artifacts/<name>/graph/`.
4. Syft → `artifacts/<name>/sbom.cdx.json`.
5. **Path O:** configure openai-compatible → Studio Ollama; run
   `openwiki code --update --print` (init if needed); copy OKF output to `openwiki-okf/`.
6. **Path C:** generate thin custom docs:
   - `overview` (facet + pack excerpts, slotted prose via same Studio model)
   - `tech-inventory` from syft only (no LLM dependency rows)
   - optional 1–2 `cluster-*` pages from gitnexus facets if cheap
7. Dry-run Moneta: heading-sized nuggets for both paths with illustrative tags/metadata
   (`kind:codebase_doc`, `repo:`, digests, `idempotencyKey`, `brainPath`). Write JSON only.
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
| Frontmatter | OKF base usable; nwl extensions (`repo`, `sha`, digests, `docType`) fit without fighting the tool |
| Moneta fit | Heading-sized nuggets look recall-worthy; provenance fields populate cleanly |
| Cost/ops | Runtime, tokens/time, failure modes, Studio Ollama quirks via openai-compatible |
| Diff friendliness | Incremental `--update` behavior vs full regen |

**Allowed decision outcomes**

1. **Adopt Path O** as narrative producer; keep gitnexus + repomix + syft.
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
  templateVersion: openwiki-0.2   # or custom-spike-1
brainPath: docs/codebases/moneta/overview.md
status: generated
```

### Dry-run Moneta nugget (illustrative)

Same shape as the parent spec: short `content`, tags including `kind:codebase_doc` and `repo:`,
provenance in `metadata` (`sha`, `slug`, `brainPath`, digests, `idempotencyKey`). No `/capture`
calls during the spike.

---

## 9. Parent-spec changes if Path O wins

### Keep unchanged

- Push → Argo Job orchestration
- repomix pack
- gitnexus analyze + shared GitNexus (later)
- syft SBOM as deterministic inventory truth
- Moneta as recall sink (`kind:codebase_doc`)
- Astro central brain as human docs site
- Publish order: R2 → Moneta → brain PR
- No SessionStart auto-inject of codebase docs

### Change

| July 15 | If openwiki wins |
| --- | --- |
| Custom facet → Ollama slot-fill → hand-rolled MDX templates | **openwiki code mode** produces narrative OKF markdown |
| Custom Zod frontmatter from scratch | **OKF base** + nwl extensions validated by Zod |
| Custom templates for overview / inventory / cluster-* | **openwiki owns narrative**; **syft owns inventory**; clusters from openwiki taxonomy and/or thin gitnexus supplements |
| Reject openwiki (#40) | **Adopt as doc producer** (not as gitnexus replacement) |
| Ollama only for slotted prose | Ollama via openwiki openai-compatible + any remaining custom inventory/cluster glue |

### Hybrid fallback

If monorepo quality is uneven: openwiki for overview/architecture; always custom syft inventory;
gitnexus facet cluster pages only when openwiki flattens packages.

### What this spike alone will not claim

- Full Argo readiness
- Production Moneta supersede semantics
- Shared GitNexus Container readiness

---

## 10. Success criteria for the spike

- Both repos produce Path O and Path C artifacts under `/tmp/codebase-brain-openwiki-spike/`.
- Dry-run Moneta JSON exists for both paths on both repos.
- Scorecards + `scorecard-summary.md` recommend adopt / keep / hybrid with evidence.
- Explicit notes on: Studio Ollama via openai-compatible reliability; OKF → Astro adapter effort;
  `olympus-sdk` package discoverability.
- Parent design ([2026-07-15](2026-07-15-codebase-brain-pipeline-design.md)) and #40 are updated
  only **after** the spike recommendation is accepted — not during the spike itself.

---

## 11. Open implementation choices (not blocking design approval)

1. Exact Studio Ollama host/URL on the tailnet for openai-compatible base URL.
2. Whether Path C is a minimal Bun/TS script in the spike workspace or ad-hoc prompts with a
   fixed template skeleton.
3. Whether gitnexus facets are exported via existing CLI output or a small extract script.
4. Whether to keep spike artifacts only under `/tmp` or also copy the decision packet into
   `docs/superpowers/` after review.
