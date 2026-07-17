# Codebase Brain Pipeline — Design Spec

**Date:** 2026-07-15  
**Status:** Accepted direction (openwiki Layer 1 adopted 2026-07-17)  
**Scope:** Project 2 of the repomix/brain work. Closes the brain *destination* seam deferred from
[repomix pipeline](2026-07-12-repomix-pipeline-design.md) and
[gitnexus graph freshness](2026-07-12-gitnexus-graph-freshness-design.md)
(nix-darwin-hm [#39](https://github.com/nwlnexus/nix-darwin-hm/issues/39) / openwiki [#40](https://github.com/nwlnexus/nix-darwin-hm/issues/40)).

**Related systems:** `scripts/repomix-pack` (Phase 1–2 producers), Moneta (memory backend),
mnemosyne (session plugin), Olympus on-prem (Argo Events/Workflows), Cloudflare (Moneta + shared
GitNexus Containers later), openwiki (Layer 1 narrative).

**Spike decision (2026-07-17):** Path O wins as Layer 1 narrative producer —
[openwiki spike results](2026-07-17-codebase-brain-openwiki-spike-results.md). OpenWiki **code
mode** + Anthropic; **syft** keeps deterministic inventory; gitnexus + shared MCP unchanged
(contract **C**). OpenWiki **personal** mode remains rejected.

---

## 1. Problem

Phase 1–2 produce per-repo **repomix packs** and **GitNexus graphs** (Mac launchd today). They do
not yet:

1. Produce **human-facing technical docs** (Astro-ready OKF / MDX with structured frontmatter).
2. **Distill** those docs into Moneta for agent recall across repos.
3. Publish graphs to R2 and expose structural queries via a **canonical shared GitNexus MCP**
   (session-local when present; remote when cwd lacks the index).
4. Run on **push-to-main** with on-prem compute instead of a always-on laptop sweep.

Agents often need *how another project did X* while working in a different repo. Current tools bias
toward cwd; graphs are machine-local; narrative knowledge is not systematically captured.

---

## 2. Goals / non-goals

### Goals

- Closed loop: `push → main` → on-prem Job → pack + graph + SBOM + openwiki narrative + syft
  inventory → sinks.
- Dual-purpose docs: Astro site content **and** Moneta nuggets (same source, different shapes).
- Layer 1: **repomix** (corpus) + **openwiki code mode** (narrative OKF via Anthropic).
- Deterministic inventory: **syft** CycloneDX → tech-inventory pages (never LLM-authored deps).
- Cross-repo: Moneta for discovery/patterns; **shared GitNexus MCP** for structural deep dive
  (on demand). Moneta stores graph **refs only**; mnemosyne may hint/orchestrate pulls via those
  same refs — it does not embed or serve the graph.
- Reuse Moneta / adapt patterns from mnemosyne; retire Mac launchd as part of cutover.

### Non-goals (this spec)

- Replacing GitNexus with embeddings or dumping full graphs into Vectorize.
- Auto-injecting codebase docs (or graphs) on mnemosyne SessionStart (episodic recall stays default).
- Running `gitnexus analyze` inside Cloudflare Workers.
- Making Moneta a graph database or graph query router.
- OpenWiki **personal** mode (multi-source Gmail/Notion/HN brain).
- Using Studio Ollama as the openwiki LLM backend (spike: unstable / unusable for wiki init).
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
                           1 pack (repomix)                 [Layer 1]
                           2 analyze (gitnexus)
                           3 SBOM (syft)                    [deterministic]
                           4 facet extract                  [deterministic; optional supplements]
                           5 openwiki code → Anthropic      [Layer 1 narrative]
                           6 syft → tech-inventory          [no LLM]
                           7 normalize OKF + nwl extensions + validate
                           8a R2 graph publish
                           8b Moneta /capture nuggets
                           8c PR → central brain repo (Astro)

Agents:
  mnemosyne SessionStart → Moneta episodic only
  on demand → Moneta recall (kind:codebase_doc, any repo)
               metadata may include graphUri / graphDigest (refs only)
  on demand → shared GitNexus MCP  ← CANONICAL structural path
               (CF Container from R2; session-local GitNexus when cwd has the index)
  later     → mnemosyne convenience: use Moneta refs to wake/hint the same MCP
               (never embeds or serves the graph itself)
```

**Mental model**

| Store | Answers |
| --- | --- |
| Astro brain (OKF → MDX/MD) | Human-readable technical docs |
| Moneta | Cross-repo narrative nuggets / patterns + **graph refs** (not graph bodies) |
| Shared GitNexus MCP | **Canonical** structural how / blast-radius across repos |
| Session-local GitNexus | Same engine when the index is already in the working tree |
| R2 graph objects | Freshness / hydration source for shared serve |
| Pack + SBOM artifacts | Raw corpus + dependency truth |

**Locked (2026-07-17) — graph consumer contract:** **C** — shared GitNexus MCP is canonical;
mnemosyne may later add convenience on the **same R2 refs**; Moneta stores refs only and never
mediates graph queries.

**Locked (2026-07-17) — Layer 1 narrative:** **Path O** — openwiki code mode + Anthropic;
syft owns inventory; openwiki does **not** replace gitnexus.

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

Single container (or init+main) that packages: **`repomix`**, **`gitnexus`**, **`openwiki`**,
**`syft`**, validator, publisher. All four CLIs must be callable on PATH.

Stages:

1. Shallow clone at exact webhook `sha`.
2. Repomix pack (existing ignore rules, including `.gitnexus/**`).
3. `gitnexus analyze` (graph under workspace `.gitnexus/`).
4. Syft → CycloneDX `sbom.cdx.json`.
5. Facet extract → `facet.json` (clusters, entrypoints, related hints — used for supplements /
   skip gates, not as the primary narrative source).
6. **openwiki code** (`--update` / init as needed) → Anthropic → OKF markdown in a Job-owned
   output dir (never commit openwiki’s `AGENTS.md` / `CLAUDE.md` / workflow mutations into source
   or brain without stripping).
7. Render **tech-inventory** from syft only (no LLM dependency rows).
8. Post-normalize: stamp nwl frontmatter extensions; validate (OKF base + nwl schema; inventory
   tables ⊆ SBOM).
9. Publish: **R2 → Moneta → brain PR** (see §6).

**Concurrency:** serialize per repo. Workflow name / mutex `brain-{owner}-{repo}`. Rapid pushes
**coalesce** to the latest sha (supersede in-flight). Never run concurrent openwiki processes on
the same working tree (spike: corrupts shared tree).

**Skip LLM** when `(packHash, graphDigest, sbomDigest, templateVersion)` unchanged since last
success (marker object in R2 or brain `manifest.json`). Prefer openwiki `--update` over full
init on steady state.

### 4.3 LLM (narrative via openwiki)

- **Primary:** Anthropic via openwiki’s native provider (spike: `claude-sonnet-4-5` worked;
  pin model id in Job config).
- **Scope:** openwiki owns multi-file narrative wiki generation from the repo (+ pack context as
  openwiki uses it). Never invent dependency lists or graph edges.
- **Not for openwiki:** Studio Ollama / openai-compatible local models (spike: hangs, empty
  output, AGENTS.md mutation without wiki).
- **Optional later:** tiny custom glue slots only if needed; not the narrative path.
- **mnemosyne:** not used in the Job. Optional later: share prompt/HTTP client utilities only.
- **Cost gate:** digest skip + `--update` + page budgets; fleet init is multi-minute per repo
  (spike: olympus-sdk ~18 min) — acceptable for push Jobs with coalescing, not laptop sweeps.

### 4.4 Content set (v1)

Per repo, into the central brain:

| Artifact | Source | LLM? |
| --- | --- | --- |
| OpenWiki OKF pages (overview, architecture, per-service/package, …) | openwiki code mode | yes (Anthropic) |
| `tech-inventory` (MD/MDX) | SBOM render | no |
| `sbom.cdx.json` + `facet.json` + `graph-ref` metadata | tools | no |
| Optional thin `cluster-*` supplements | GitNexus facets | only if openwiki taxonomy underserves a repo |

Richer process/route pages are explicitly v2+. Source-repo clones must not retain openwiki’s
side effects (`AGENTS.md` / `CLAUDE.md` / `.github/workflows/openwiki-*.yml`) in the brain PR.

### 4.5 Moneta ingestion

- Batch client of existing Moneta `/capture` (same sink mnemosyne uses), not a new Vectorize index.
- Small nuggets (heading-sized), not whole wiki files.
- Tags include `kind:codebase_doc`, `repo:{name}`, `docType:{…}`.
- Provenance in `metadata` (excluded from embedding per Moneta today): `sha`, `slug`, `brainPath`,
  digests, `idempotencyKey`, `relatedRepos`, **`graphDigest`**, **`graphUri`** (R2 pointer only).
- Nugget **content** must never include graph dumps or edge lists — refs only.
- Inventory pages: at most one short summary nugget; full CycloneDX stays in brain/R2.
- **SessionStart:** do **not** auto-inject codebase docs or graphs. On-demand `recall` with filters.
- Supersede: after success, mark/forget prior `codebase_doc` rows for that repo with older `sha`
  (or rely on idempotency keys + status) so stale architecture does not dominate recall.

### 4.6 Shared GitNexus (Cloudflare) — publish A, serve as canonical MCP

**Graph consumer contract (locked):** shared GitNexus MCP is the canonical structural path.
Session-local GitNexus is fine when the index is already present. mnemosyne may later use Moneta
`graphUri`/`graphDigest` to hint or wake that **same** MCP — convenience only. Moneta never
answers `impact`/`query` itself. OpenWiki does not replace GitNexus.

- **Publish (Job):** Analyze stays in the on-prem Job. Publish `.gitnexus` tarball to R2
  (`graphs/{owner}/{repo}/{sha}.tgz` + `…/latest`) plus digests used in Moneta/brain metadata.
- **Serve (canonical):** Cloudflare **Container** runs `gitnexus serve` (or equivalent
  MCP-over-HTTP), Worker + Access/service auth in front. Sleep when idle. Hydrate from R2
  `latest` / sha object.
- **Later (facets):** Worker-served **facets** for cheap discovery without waking Containers; deep
  `impact`/`trace` still hits Container GitNexus.
- **Not Workers-native LadybugDB.** Do not open `lbug` inside a Worker.
- Agents invoke shared GitNexus MCP **only when needed** (not SessionStart).

### 4.7 Central brain + Astro

- Hybrid ownership: generated OKF/MDX + SBOM + facets live in a **central brain repo** (Astro
  content collections). Source repos are not required to host the docs site.
- One open PR branch per repo: `automation/brain-{repo}`; push updates onto it until merge.
- Frontmatter: **OKF base + nwl extensions**, validated by Zod (see §5). Astro consumes the same
  files humans read (adapter as needed for `.md` vs `.mdx`).

---

## 5. Frontmatter and Moneta contracts

### 5.1 Doc frontmatter (OKF base + nwl extensions)

**OKF base (from openwiki):** e.g. `type`, `title`, `description`, `tags`, `resource` /
`timestamp` as produced.

**Nwl extensions (pipeline stamps post-generation):**

```yaml
docType: overview          # overview | inventory | cluster | …
repo: moneta
owner: nwlnexus
slug: moneta/overview
source:
  sha: …
  packHash: sha256:…
  graphDigest: sha256:…
  graphUri: r2://graphs/nwlnexus/moneta/<sha>
  templateVersion: openwiki-0.2
brainPath: docs/codebases/moneta/overview.md
status: generated
```

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
    "graphUri": "r2://graphs/nwlnexus/moneta/…",
    "relatedRepos": ["mnemosyne"]
  }
}
```

Full CycloneDX stays in brain/R2; at most one short inventory summary nugget in Moneta.
Graph bodies stay in R2 / GitNexus — never in Moneta content.

---

## 6. Publish order and failure

**Order:** R2 graph upload → Moneta nuggets → brain PR update.  
Rationale: machine artifacts before human-visible docs; PR implies sinks already have the sha.

**Failure**

- Retry: clone, R2, Moneta network errors (bounded).
- LLM / openwiki: at most one retry (optionally cheaper Anthropic model); then fail Workflow.
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
- Job holds Anthropic credentials for openwiki (secret store / ExternalSecrets); no public Ollama
  requirement for narrative.
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
| mnemosyne | **Reuse** episodic SessionStart; **later** convenience to hint/wake shared GitNexus MCP from Moneta refs (never serve the graph) |
| openwiki code mode | **Adopt** as Layer 1 narrative producer (Anthropic); personal mode rejected |
| Ollama on Mac Studio | **Not** for openwiki; optional later only for tiny custom glue |
| GitHub App patterns | **Reuse** / extend |
| Argo Events + Workflows | **New** (ArgoCD remains retired; Flux stays for gitops apps) |
| Syft SBOM + OKF→nwl normalize + validator | **New** |
| Central brain Astro repo | **New** (or designate existing second-brain/docs repo — implementation choice) |
| R2 graph publish + CF Container GitNexus | **New** (may phase after Job→brain→Moneta works) |

---

## 9. Phased delivery

1. **Job MVP:** webhook → Workflow → pack + analyze + SBOM + facets; graph tarball + refs to R2; no LLM.
2. **Layer 1 narrative + brain PR:** openwiki (Anthropic) + OKF/nwl adapter + syft inventory +
   validator + PR. Strip openwiki side-effect files from publish set.
3. **Moneta nuggets:** capture + supersede + agent on-demand recall; metadata includes `graphUri` /
   `graphDigest` (refs only).
4. **Shared GitNexus Container (canonical MCP):** serve from R2 `latest`; remote MCP; sleep-when-idle;
   verify `impact`/`query` for a non-local repo.
5. **mnemosyne convenience (optional):** use Moneta graph refs to hint/wake the same MCP when a task
   needs structural detail — still not SessionStart auto-inject.
6. **Cutover:** disable/remove launchd; expand allowlist; optional Worker-served facets.
7. **Later:** process pages, vuln planning from SBOM, work org repos.

---

## 10. Open implementation choices (not blocking design approval)

1. Exact central brain repository name and Astro content collection path layout.
2. Whether Job packages `repomix-pack` as a library vs shelling a published CLI.
3. Argo Events deployment home in olympus-gitops (namespace, ExternalSecrets).
4. R2 bucket naming and retention (how many historical shas).
5. Pinned Anthropic model id and openwiki CLI version in the Job image.
6. Exact strip/ignore list for openwiki side effects (`AGENTS.md`, `CLAUDE.md`, workflow files).

---

## 11. Success criteria

- Push to allowlisted `main` produces a green Workflow for that sha without Mac involvement.
- Brain PR reviewable docs with valid OKF + nwl frontmatter; Astro build consumes them.
- Syft inventory pages match CycloneDX; no LLM-invented dependency rows.
- Moneta `recall` with `kind:codebase_doc` + `repo:` returns nuggets for another repo while cwd is elsewhere;
  nugget metadata carries `graphUri`/`graphDigest` without graph bodies.
- Graph for that sha exists in R2; **shared GitNexus MCP** (phase 4) can answer `impact`/`query` for a
  non-local repo (canonical structural path).
- Launchd repomix timers removed; docs updated; no dual writers racing the same brain branch.
