# Codebase Brain Pipeline — Design Spec

**Date:** 2026-07-15  
**Status:** Draft for review  
**Scope:** Project 2 of the repomix/brain work. Closes the brain *destination* seam deferred from
[repomix pipeline](2026-07-12-repomix-pipeline-design.md) and
[gitnexus graph freshness](2026-07-12-gitnexus-graph-freshness-design.md)
(nix-darwin-hm [#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39) / openwiki [#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40)).

**Related systems:** `scripts/repomix-pack` (Phase 1–2 producers), Moneta (memory backend),
mnemosyne (session plugin), Olympus on-prem (Argo Events/Workflows), Cloudflare (Moneta + shared
GitNexus Containers later).

---

## 1. Problem

Phase 1–2 produce per-repo **repomix packs** and **GitNexus graphs** (Mac launchd today). They do
not yet:

1. Produce **human-facing technical docs** (Astro MDX with structured frontmatter).
2. **Distill** those docs into Moneta for agent recall across repos.
3. Publish graphs to a **shared online GitNexus** so structural queries work when the local machine
   does not have every index.
4. Run on **push-to-main** with on-prem compute instead of a always-on laptop sweep.

Agents often need *how another project did X* while working in a different repo. Current tools bias
toward cwd; graphs are machine-local; narrative knowledge is not systematically captured.

---

## 2. Goals / non-goals

### Goals

- Closed loop: `push → main` → on-prem Job → pack + graph + SBOM + facets + slotted MDX → sinks.
- Dual-purpose MDX: Astro site content **and** Moneta nuggets (same source, different shapes).
- Template-heavy generation: deterministic extracts first; LLM fills prose slots only.
- Cross-repo: Moneta for discovery/patterns; shared GitNexus for structural deep dive (on demand).
- Reuse Moneta / adapt patterns from mnemosyne; retire Mac launchd as part of cutover.
- SBOM as a real CycloneDX artifact (vuln planning later), not LLM-invented dependency lists.

### Non-goals (this spec)

- Replacing GitNexus with embeddings or dumping full graphs into Vectorize.
- Auto-injecting codebase docs on mnemosyne SessionStart (episodic recall stays default).
- Running `gitnexus analyze` inside Cloudflare Workers.
- Adopting openwiki as the wiki engine ([#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40)
  remains a reject-by-default unless a later spike overturns it — this design does not use it).
- Automated CVE remediation PRs (SBOM enables later planning only).
- Work GitHub org (`dtlr`) in v1 allowlist (personal/`nwlnexus` first).

---

## 3. Architecture overview

```text
GitHub (nwlnexus)  --push main-->  org webhook
                                      |
                                      v
                         Argo Events (signature verify)
                                      |
                                      v
                         Argo Workflow (mutex per repo)
                                      |
                                      v
                         Job container @ pinned sha
                           GitHub App clone
                           1 pack (repomix)
                           2 analyze (gitnexus)
                           3 SBOM (syft)              [deterministic]
                           4 facet extract            [deterministic]
                           5 MDX slots ← Ollama       [Mac Studio / tailnet]
                           6 validate
                           7a R2 graph publish
                           7b Moneta /capture nuggets
                           7c PR → central brain repo (Astro MDX)

Agents:
  mnemosyne SessionStart → Moneta episodic only
  on demand → Moneta recall (kind:codebase_doc, any repo)
  on demand → shared GitNexus MCP (CF Container; facets later)
```

**Mental model**

| Store | Answers |
| --- | --- |
| Astro MDX (brain repo) | Human-readable technical docs |
| Moneta | Cross-repo narrative nuggets / patterns |
| Shared GitNexus | Structural how/blast-radius across repos |
| Pack + SBOM artifacts | Raw corpus + dependency truth |

---

## 4. Component decisions

### 4.1 Producers → on-prem Argo (retire launchd)

- **Orchestrator:** Argo Events + Argo Workflows on the Olympus on-prem cluster.
- **Trigger:** Org-level GitHub webhook, `push` to default branch (`main`), allowlisted repos
  (sourced from the same inventory spirit as `modules/repomix/repos.toml` — ConfigMap/CRD copy).
- **Auth to GitHub:** GitHub App (clone + open PRs to brain repo). Align with existing App patterns
  used in olympus-sdk / edge bootstrap.
- **Cutover:** Once Workflows are trusted for the allowlist, **remove** Mac launchd scheduling for
  `repomix-pack`. No standby laptop sweep.

### 4.2 Job image and stages

Single container (or init+main) that packages Bun/Node tooling: repomix, gitnexus, syft, validator,
publisher. Stages:

1. Shallow clone at exact webhook `sha`.
2. Repomix pack (existing ignore rules, including `.gitnexus/**`).
3. `gitnexus analyze` (graph under workspace `.gitnexus/`).
4. Syft → CycloneDX `sbom.cdx.json`.
5. Facet extract → `facet.json` (clusters, entrypoints, related hints, tech summary).
6. MDX slot-fill via Ollama on Mac Studio (tailnet).
7. Validate (frontmatter schema, required sections, inventory tables must match SBOM).
8. Publish: **R2 → Moneta → brain PR** (see §6).

**Concurrency:** serialize per repo. Workflow name / mutex `brain-{owner}-{repo}`. Rapid pushes
**coalesce** to the latest sha (supersede in-flight).

**Skip LLM** when `(packHash, graphDigest, sbomDigest, templateVersion)` unchanged since last
success (marker object in R2 or brain `manifest.json`).

### 4.3 LLM (MDX only)

- **Primary:** Ollama on Mac Studio via tailnet; prefer warm `qwen3.6:27b-mlx`; fallback
  `qwen2.5:7b-instruct` on timeout.
- **Scope:** fill slotted prose (`TL;DR`, `Architecture`, `Gotchas`) given facet JSON + cited pack
  excerpts. Never invent dependency lists or graph edges.
- **Out of scope for v1:** Cloudflare Workers AI failover (optional later if Studio is down).
- **mnemosyne:** not used in the Job. Optional later: share prompt/HTTP client utilities only.

### 4.4 Content set (v1 = minimal)

Per repo, into the central brain:

| Artifact | Source | LLM? |
| --- | --- | --- |
| `overview.mdx` | facet + pack | slots only |
| `tech-inventory.mdx` | SBOM render | no |
| `cluster-{name}.mdx` for top clusters | GitNexus cluster facet | slots only |
| `sbom.cdx.json` + `facet.json` | tools | no |

Richer process/route pages are explicitly v2+.

### 4.5 Moneta ingestion

- Batch client of existing Moneta `/capture` (same sink mnemosyne uses), not a new Vectorize index.
- Small nuggets (heading-sized), not whole MDX files.
- Tags include `kind:codebase_doc`, `repo:{name}`, `docType:{…}`.
- Provenance in `metadata` (excluded from embedding per Moneta today): `sha`, `slug`, `brainPath`,
  digests, `idempotencyKey`, `relatedRepos`.
- **SessionStart:** do **not** auto-inject codebase docs. On-demand `recall` with filters.
- Supersede: after success, mark/forget prior `codebase_doc` rows for that repo with older `sha`
  (or rely on idempotency keys + status) so stale architecture does not dominate recall.

### 4.6 Shared GitNexus (Cloudflare) — start A, design for C

- **v1 path (A):** Analyze stays in the on-prem Job. Publish `.gitnexus` tarball to R2
  (`graphs/{owner}/{repo}/{sha}.tgz` + `…/latest`). Cloudflare **Container** runs `gitnexus serve`
  (or equivalent MCP-over-HTTP), Worker + Access/service auth in front. Sleep when idle.
- **Later (C):** Worker-served **facets** for cheap discovery without waking Containers; deep
  `impact`/`trace` still hits Container GitNexus.
- **Not Workers-native LadybugDB.** Do not open `lbug` inside a Worker.
- Agents invoke shared GitNexus MCP **only when needed** (not SessionStart).

### 4.7 Central brain + Astro

- Hybrid ownership: generated MDX + SBOM + facets live in a **central brain repo** (Astro content
  collections). Source repos are not required to host the docs site.
- One open PR branch per repo: `automation/brain-{repo}`; push updates onto it until merge.
- Frontmatter is a versioned Zod schema (see §5). Astro parser consumes the same files humans read.

---

## 5. Frontmatter and Moneta contracts

### 5.1 MDX frontmatter (illustrative)

Required fields: `title`, `description`, `docType`, `repo`, `owner`, `slug`, `sidebar`, `tags`,
`technologies`, `related`, `gitnexus` (hints), `source` (`sha`, digests, `templateVersion`,
`generatedAt`), `status`.

`docType`: `overview` | `cluster` | `inventory` (v1).

Inventory pages must render SBOM-derived tables; agents must not author dependency rows.

### 5.2 Moneta nugget (illustrative)

```json
{
  "content": "…single claim / short paragraph…",
  "tags": ["kind:codebase_doc", "repo:moneta", "docType:overview", "topic:architecture"],
  "metadata": {
    "kind": "codebase_doc",
    "repo": "moneta",
    "owner": "nwlnexus",
    "sha": "…",
    "slug": "moneta/overview",
    "heading": "TL;DR",
    "brainPath": "docs/codebases/moneta/overview.mdx",
    "idempotencyKey": "codebase_doc:moneta:…:overview:tldr",
    "packHash": "sha256:…",
    "graphDigest": "sha256:…",
    "relatedRepos": ["mnemosyne"]
  }
}
```

Full CycloneDX stays in brain/R2; at most one short inventory summary nugget in Moneta.

---

## 6. Publish order and failure

**Order:** R2 graph upload → Moneta nuggets → brain PR update.  
Rationale: machine artifacts before human-visible docs; PR implies sinks already have the sha.

**Failure**

- Retry: clone, R2, Moneta network errors (bounded).
- LLM: at most one retry with fallback model; then fail Workflow.
- Validate fail: no R2 `latest` move, no Moneta write, no brain push; retain failed artifacts for debug.
- Slack/notify on failure (reuse existing notify secret patterns where possible).

**Idempotency**

- Moneta: `idempotencyKey` per nugget; server-side dedupe if available, else client get-or-update.
- Brain: force-push or commit onto the single automation branch for that repo.
- R2: immutable sha object; `latest` updated only on full success.

---

## 7. Security and allowlisting

- Verify GitHub webhook signatures in Argo Events.
- GitHub App: least privilege — contents read on source repos; contents/PRs on brain repo only.
- Job pulls Studio Ollama only over tailnet; no public Ollama.
- Moneta: existing service auth / Access patterns (same as mnemosyne drain).
- Shared GitNexus gateway: Cloudflare Access or service credentials; no anonymous MCP.
- Allowlist refuses repos outside inventory (prevents org-wide surprise Jobs).

---

## 8. What is reused vs new

| Piece | Disposition |
| --- | --- |
| `scripts/repomix-pack` pack + graph logic | **Reuse** inside Job image (extract library or invoke packaged CLI) |
| Mac launchd sweep | **Retire** after cutover |
| Moneta capture/recall/MCP/Vectorize | **Reuse** as KB backend |
| mnemosyne | **Unchanged** for this pipeline (session episodic only) |
| Ollama on Mac Studio | **Reuse** as MDX LLM |
| GitHub App patterns | **Reuse** / extend |
| Argo Events + Workflows | **New** (ArgoCD remains retired; Flux stays for gitops apps) |
| Syft SBOM + facet extract + MDX templates/validator | **New** |
| Central brain Astro repo | **New** (or designate existing second-brain/docs repo — implementation choice) |
| R2 graph publish + CF Container GitNexus | **New** (may phase after Job→brain→Moneta works) |

---

## 9. Phased delivery

1. **Job MVP:** webhook → Workflow → pack + analyze + SBOM + facets; artifacts to R2 staging; no LLM.
2. **MDX + brain PR:** templates + Ollama slots + validator + PR.
3. **Moneta nuggets:** capture + supersede + agent on-demand recall verified.
4. **Shared GitNexus Container:** serve from R2 `latest`; remote MCP; sleep-when-idle.
5. **Cutover:** disable/remove launchd; expand allowlist; optional facets-on-Workers (C).
6. **Later:** process pages, vuln planning from SBOM, Workers AI LLM failover, work org repos.

---

## 10. Open implementation choices (not blocking design approval)

1. Exact central brain repository name and Astro content collection path layout.
2. Whether Job packages `repomix-pack` as a library vs shelling a published CLI.
3. Argo Events deployment home in olympus-gitops (namespace, ExternalSecrets).
4. R2 bucket naming and retention (how many historical shas).
5. openwiki [#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40): closed as **not adopted** by this design unless explicitly reopened.

---

## 11. Success criteria

- Push to allowlisted `main` produces a green Workflow for that sha without Mac involvement.
- Brain PR reviewable MDX with valid frontmatter; Astro build consumes it.
- Moneta `recall` with `kind:codebase_doc` + `repo:` returns nuggets for another repo while cwd is elsewhere.
- Graph for that sha exists in R2; shared GitNexus (phase 4) can answer `impact`/`query` for a non-local repo.
- Launchd repomix timers removed; docs updated; no dual writers racing the same brain branch.
