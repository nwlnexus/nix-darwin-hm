# Codebase Brain Job

On-prem Argo Job (Bun/TypeScript) that runs on a pinned Git SHA: shallow clone → repomix pack →
gitnexus analyze → syft SBOM → optional openwiki (Anthropic) narrative → OKF normalization →
tech-inventory → R2 graph publish → PR to the central brain repo. It produces Astro-ready narrative
docs plus structural graph references for the codebase brain pipeline (Moneta nuggets and shared
GitNexus MCP are downstream; phases 3–4 are not implemented here).

## Prerequisites

Tools must be on `PATH` when running locally (the Containerfile installs them in the image):

- `bun` — runtime and tests
- `git` — clone and brain-repo PR
- `tar` — graph tarball
- `syft` — CycloneDX SBOM
- `repomix` — corpus pack
- `gitnexus` — graph analyze
- `openwiki` — Layer 1 narrative (`openwiki code`)

For phase 2 / `--phase all`, you also need `gh` on `PATH` when not using `--dry-run`.

## Install

```bash
cd scripts/codebase-brain && bun install
```

## CLI usage

```bash
bun run src/index.ts --owner nwlnexus --repo MY_REPO --sha COMMIT_SHA [flags]
```

| Flag | Default | Description |
| --- | --- | --- |
| `--owner` | `nwlnexus` | GitHub org/user for the source repo |
| `--repo` | *(required)* | Source repository name |
| `--sha` | *(required)* | Commit SHA to clone and analyze |
| `--phase` | `all` | `1` = structural stages only; `2` or `all` = run openwiki + brain PR when skip gate allows |
| `--work-root` | `/tmp/codebase-brain-job` | Root for clones, outputs, and brain-repo checkout |
| `--dry-run` | `false` | Skip R2 uploads, git push, and `gh pr create`; still runs tools and writes local `out/` |
| `--brain-repo` | `second-brain` | Central brain GitHub repo name (under `--owner`) |
| `--config-path` | `modules/repomix/repomix.config.json` (resolved from `src/index.ts`) | Repomix config passed to `repomix --config` |

Example (structural only, local):

```bash
bun run src/index.ts --repo nix-darwin-hm --sha abc1234 --phase 1 --dry-run
```

## Phases and LLM skip gate

Every run executes the **structural pipeline** (clone → pack → analyze → facets → SBOM → R2 graph
publish → write `manifest.json`), regardless of `--phase`. The digests marker (`latest-digests.json`)
is written only after openwiki + normalize + inventory + brain PR succeed (phase `2`/`all` success
path) — not on `--phase 1` or the skip path. Local dry-run of `--phase all` still writes the local
marker so a second dry-run can skip.

| `--phase` | After structural stages |
| --- | --- |
| `1` | Stop (no openwiki, no brain PR) |
| `2`, `all` | Continue unless the **skip gate** matches |

**Skip gate:** before openwiki, the Job compares current digests to the previous marker:

- `packHash`, `graphDigest`, `sbomDigest`, `templateVersion` (`openwiki-0.2`)
- Previous marker: R2 `graphs/{owner}/{repo}/latest-digests.json` when AWS creds are set; otherwise
  local `{work-root}/out/{owner}/{repo}/latest-digests.json`
- On match, phase 2/all logs `skip LLM: digests unchanged` and exits without openwiki or brain PR

Phase 2/all (when not skipped): `openwiki code --update` (Anthropic only) → strip side effects →
normalize OKF + nwl frontmatter → `tech-inventory.md` from SBOM → open/update PR on
`automation/brain-{repo}`.

## Environment variables

Runtime secrets — never commit. The Containerfile lists the same set.

| Variable | When required | Purpose |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | Phase 2 / `all` (openwiki) | Anthropic provider for openwiki (`OPENWIKI_PROVIDER=anthropic`) |
| `AWS_ENDPOINT_URL` | R2 upload / remote skip marker | Cloudflare R2 S3-compatible endpoint |
| `AWS_ACCESS_KEY_ID` | R2 upload / remote skip marker | R2 access key |
| `AWS_SECRET_ACCESS_KEY` | R2 upload / remote skip marker | R2 secret key |
| `BRAIN_R2_BUCKET` | Optional | Bucket name (default `nwl-codebase-brain`) |
| `GH_TOKEN` | Brain PR (non–dry-run) | `gh` auth for push and PR create/edit |
| `OPENWIKI_MODEL_ID` | Optional | Override openwiki model (otherwise openwiki default) |

Without R2 creds, graph upload and remote digest fetch are skipped; local `out/` artifacts are always
written. `latest-digests.json` is written only after phase `2`/`all` succeeds (local dry-run included).

## Outputs

Under `{work-root}/out/{owner}/{repo}/{sha}/`:

| Artifact | Description |
| --- | --- |
| `repomix.xml` | Repomix pack copy |
| `graph-{sha}.tgz` | `.gitnexus/` tarball |
| `graph-ref.json` | R2 URIs + `graphDigest` |
| `manifest.json` | `{ digests, skipLlm, graph }` |
| `sbom.cdx.json` | Syft CycloneDX |
| `facet.json` | Thin v1 facet metadata |
| `brain-docs/{repo}/**` | Normalized OKF pages (subdir layout preserved) |
| `brain-docs/{repo}/tech-inventory.md` | SBOM-derived inventory (not LLM-authored) |

Digests marker (sibling of `{sha}/`): `{work-root}/out/{owner}/{repo}/latest-digests.json`.

R2 keys (when creds present): `graphs/{owner}/{repo}/{sha}.tgz`, `latest`, `latest.json`,
`latest-digests.json`.

**Brain PR:** copies `brain-docs/{repo}/` → `docs/codebases/{repo}/` and
`sbom.cdx.json`, `facet.json`, `graph-ref.json` → `docs/codebases/{repo}/_meta/` in
`{owner}/{brain-repo}` (default `nwlnexus/second-brain`), branch `automation/brain-{repo}`.

Openwiki side effects are **not** published: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, and
`.github/workflows/openwiki-*.yml` are filtered when copying from the repo’s `openwiki/` tree.

## Graph consumer contract (C)

Graph tarball is published to R2; the canonical structural consumer is the shared GitNexus MCP.
Moneta stores graph refs only; mnemosyne may pull on demand later — this Job publishes refs, not
Moneta nuggets or MCP serve (phases 3–4).

## Testing

```bash
cd scripts/codebase-brain
bun test
bunx tsc --noEmit
```

## Container image

Build from the **repository root** (not this directory):

```bash
podman build -f scripts/codebase-brain/Containerfile -t codebase-brain:dev .
```

See [`Containerfile`](Containerfile) for tool versions. `repomix`, `gitnexus`, and `syft` are
pinned to `latest` in the Containerfile pending a first successful image build; reproducibility
follow-up will pin versions.

Argo Events / Workflows deployment checklist (olympus-gitops):
[`docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`](../../docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md).

Implementation plan (phases 1–2):
[`docs/superpowers/plans/2026-07-17-codebase-brain-job-phases-1-2.md`](../../docs/superpowers/plans/2026-07-17-codebase-brain-job-phases-1-2.md).

Design spec:
[`docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md`](../../docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md).
