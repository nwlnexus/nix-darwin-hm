# Codebase Brain — olympus-gitops Argo Checklist

> **Audience:** cluster operator applying resources in **olympus-gitops** (not this repo).  
> **Job source:** [`scripts/codebase-brain/`](../../../scripts/codebase-brain/) in `nix-darwin-hm`.  
> **Design spec:** [`docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md`](../specs/2026-07-15-codebase-brain-pipeline-design.md)  
> **Implementation plan:** [`docs/superpowers/plans/2026-07-17-codebase-brain-job-phases-1-2.md`](2026-07-17-codebase-brain-job-phases-1-2.md) Task 13

Push to allowlisted `main` on a personal (`nwlnexus`) repo triggers an Argo Events Sensor → Argo Workflow that runs the codebase-brain Job container once per event (serialized per repo).

---

## 0. Prerequisites

- [ ] Argo Events and Argo Workflows installed and reachable from olympus-gitops (Flux manages apps; ArgoCD remains retired for this path).
- [ ] Cluster can pull images from the chosen registry and reach `github.com`, Cloudflare R2 (`AWS_ENDPOINT_URL`), and `api.anthropic.com`.
- [ ] GitHub org webhook endpoint (Ingress or existing Events gateway) ready to receive `push` events with HMAC signature verification.
- [ ] R2 bucket exists (default Job bucket: `nwl-codebase-brain`; override via `BRAIN_R2_BUCKET`).

---

## 1. Namespace and RBAC

- [ ] Create namespace `codebase-brain` (or agreed name — use consistently in all manifests below).
- [ ] ServiceAccount for Workflow pods with permission to read Secrets in that namespace (no cluster-admin).
- [ ] (Optional) ResourceQuota / LimitRange if the cluster requires CPU/memory caps for long-running LLM jobs.

---

## 2. Container image (build in nix-darwin-hm, deploy via olympus-gitops)

**Source:** [`scripts/codebase-brain/Containerfile`](../../../scripts/codebase-brain/Containerfile)

- [ ] **Build context MUST be the nix-darwin-hm repo root** — not `scripts/codebase-brain/`. The image copies `modules/repomix/repomix.config.json` and app sources from repo-root paths.
- [ ] Build and tag (example — replace registry/org/tag with your olympus-gitops convention):

```bash
# From nix-darwin-hm repo root
podman build -f scripts/codebase-brain/Containerfile \
  -t ghcr.io/nwlnexus/codebase-brain:2026-07-17 .
# or: docker build …
```

- [ ] Push to the cluster-accessible registry (e.g. `ghcr.io/nwlnexus/codebase-brain:<tag>`).
- [ ] Record the immutable tag (git SHA or date tag) in olympus-gitops; pin WorkflowTemplate `image:` to that tag (avoid `:latest` in prod).
- [ ] Workflow references the image directly on the container step (`image: ghcr.io/nwlnexus/codebase-brain:<tag>`). Entrypoint is `bun run src/index.ts`; CLI args append after the image name.
- [ ] CI option: add a nix-darwin-hm workflow that builds on merge to `main` and pushes to GHCR; olympus-gitops bumps the tag via PR.

**Tools baked in (smoke-test after build):**

```bash
podman run --rm ghcr.io/nwlnexus/codebase-brain:<tag> \
  sh -c 'which bun git tar syft repomix gitnexus openwiki'
```

---

## 3. Secrets (runtime env only — NEVER in the image)

**Principle:** secrets live in **1Password**; the cluster reads them via **ExternalSecrets** into a
namespaced Kubernetes `Secret`. Do **not** paste tokens into ConfigMaps, image layers, Flux
plaintext, or long-lived “manual” `kubectl create secret` as the source of truth. Sealed-secrets
are not the preferred path for this Job.

The Job reads **environment variables** at runtime (`envFrom: secretRef` on the Workflow container).

| Secret key / env var | Required when | 1Password → ExternalSecret (example) |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | `--phase 2`, `all` (openwiki) | `op://Dev/docs-api-key` (or dedicated item) |
| `AWS_ENDPOINT_URL` | R2 publish / skip-gate fetch | R2 item in 1Password Dev vault |
| `AWS_ACCESS_KEY_ID` | R2 publish / skip-gate fetch | same R2 item |
| `AWS_SECRET_ACCESS_KEY` | R2 publish / skip-gate fetch | same R2 item |
| `BRAIN_R2_BUCKET` | optional | default `nwl-codebase-brain` if unset (non-secret ConfigMap/env OK) |
| `GH_TOKEN` | private source clone + brain PR / `gh` | **minted** from GitHub App creds (see §3.1) — not a personal PAT |
| `OPENWIKI_MODEL_ID` | optional | non-secret; ConfigMap/env OK |

- [ ] ExternalSecrets Operator + 1Password Connect / Secrets Automation already installed (or add in olympus-gitops).
- [ ] Create ExternalSecret(s) in `codebase-brain` namespace that sync from 1Password into `codebase-brain-secrets` (split or single Secret — operator choice).
- [ ] Wire Workflow container `envFrom: secretRef: name: codebase-brain-secrets` — **no secrets in ConfigMap or image layers**.
- [ ] Confirm `gh` and `git` inside the pod authenticate via `GH_TOKEN` for allowlisted source clones **and** `nwlnexus/second-brain` push/PR.

- [ ] (Recommended) ExternalSecret for **Slack webhook** (or reuse existing notify 1Password item / pattern) for failure alerts — see §10.

### 3.1 GitHub App → `GH_TOKEN` (1Password + ExternalSecrets)

Use a dedicated org App (e.g. `codebase-brain`) for clone + brain PR — bounded, auditable bot
identity. The Job still consumes a short-lived token as **`GH_TOKEN`** (HTTPS
`x-access-token:…@github.com/…` clone and `gh`/`git` push).

**Store in 1Password (Dev vault), never in git:**

Item: **`codebase-docs-pipeline-gh-app`** (path shape: `op://Dev/codebase-docs-pipeline-gh-app/…`)

| Field (as stored) | Purpose |
| --- | --- |
| `app-id` | GitHub App ID (numeric) |
| `client-id` | GitHub App Client ID |
| `client-secret` | App client secret (OAuth-style; not required for install-token mint) |
| `installation-id` | Org installation ID on nwlnexus — required to mint install access token |
| PEM **file attachment** (`*.private-key.pem`) | App private key — ExternalSecrets / Connect must map the **document/file** property |

**PEM as file attachment:** keep the `.pem` as a 1Password **document/file** on the item (not pasted into a password field). When wiring olympus-gitops:

- [ ] ExternalSecret references item `codebase-docs-pipeline-gh-app` in the Dev vault.
- [ ] Sync `app-id`, `client-id`, `installation-id` as string keys; sync the PEM via the provider’s **file/document** reference into a Secret key such as `private_key` (raw PEM bytes, including `BEGIN/END` lines).
- [ ] Local verify (laptop only): `op item get codebase-docs-pipeline-gh-app --fields label=app-id,label=installation-id` and read the document attachment for the PEM — do not commit the output.

**Note:** JWT signing uses **App ID + PEM**; exchanging for a short-lived install token also needs **`installation-id`**. `client-id` / `client-secret` are not used by the Job’s `GH_TOKEN` mint path today.

**In cluster (olympus-gitops):**

- [ ] ExternalSecret syncs App ID / installation ID / PEM from 1Password into a K8s Secret (e.g. `codebase-brain-github-app`).
- [ ] A mint path (init container, small sidecar, or ExternalSecrets generator / CronJob) exchanges JWT → **installation access token** (~1h) and writes/refreshes `GH_TOKEN` on `codebase-brain-secrets` (or injects it for the Workflow).
- [ ] **Do not** use a personal PAT as production `GH_TOKEN`. Local smoke may use `gh auth token` only on a developer machine.
- [ ] Install the App on **selected** repos only: `[groups.personal]` allowlist + `second-brain` (see §4).

**App repository permissions (minimum):** Metadata (read); Contents (read/write); Pull requests (read/write). Webhook optional (Argo Events owns push today).

---

## 4. Allowlist ConfigMap

**Source of truth:** [`modules/repomix/repos.toml`](../../../modules/repomix/repos.toml) → `[groups.personal]` only (v1: **no** `[groups.work]` / `dtlr` repos).

- [ ] Generate ConfigMap `codebase-brain-allowlist` from the personal group:

```toml
# groups.personal.owner = nwlnexus
# repos = olympus-sdk, olympus-gitops, olympus-infra, nix-darwin-hm,
#         moneta, nix-op-secrets, second-brain, olympus-tailnet, homebrew-olympus
```

- [ ] Sensor filter: reject events where `repository.name` ∉ allowlist **before** submitting a Workflow (prevents org-wide surprise Jobs).
- [ ] Regenerate/sync allowlist when `repos.toml` changes (PR in nix-darwin-hm → PR in olympus-gitops).

Example shape (**goes in olympus-gitops**):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: codebase-brain-allowlist
  namespace: codebase-brain
data:
  owner: nwlnexus
  repos: |
    olympus-sdk
    olympus-gitops
    olympus-infra
    nix-darwin-hm
    moneta
    nix-op-secrets
    second-brain
    olympus-tailnet
    homebrew-olympus
```

---

## 5. EventSource — GitHub `push` to `main`

- [ ] Deploy Argo Events `EventSource` (HTTP webhook) with **GitHub HMAC signature verification**.
- [ ] Subscribe to `push` events for org `nwlnexus` (or repo-scoped webhooks per allowlist repo).
- [ ] Filter: branch ref `refs/heads/main` only.
- [ ] Extract and pass through payload fields needed by the Sensor:
  - `owner` — `repository.owner.login` (expect `nwlnexus`)
  - `repo` — `repository.name`
  - `sha` — `after` (commit SHA)

Example filter expression (**goes in olympus-gitops** — adjust to your Events version):

```yaml
# Sensor trigger filter (illustrative)
filters:
  data:
    - path: body.ref
      type: string
      value:
        - refs/heads/main
    - path: body.repository.owner.login
      type: string
      value:
        - nwlnexus
```

---

## 6. Sensor → Workflow (mutex + coalesce)

### 6.1 Trigger wiring

- [ ] `Sensor` listens to the EventSource and creates/submits a `Workflow` (via `WorkflowTemplate` + parameters).
- [ ] Map event payload → Workflow parameters: `owner`, `repo`, `sha`.
- [ ] Default production invocation: **`--phase all`** (full pipeline). See §8 for phase overrides.

### 6.2 CRITICAL — per-repo mutex `brain-{owner}-{repo}`

The Job uses a **shared clone directory per repo**, not per SHA:

```text
{work-root}/repos/{owner}/{repo}   ← shared across SHAs (openwiki writes here)
{work-root}/out/{owner}/{repo}/{sha}  ← per-SHA outputs
```

Concurrent Workflows for the same repo corrupt the openwiki working tree. **Require** Argo Workflows synchronization:

- [ ] Set mutex name to **`brain-{{workflow.parameters.owner}}-{{workflow.parameters.repo}}`** (literal pattern: `brain-nwlnexus-moneta`, etc.).
- [ ] Only one Workflow per repo may run at a time; additional events wait on the mutex.

Example (**goes in olympus-gitops**):

```yaml
spec:
  synchronization:
    mutex:
      name: "brain-{{workflow.parameters.owner}}-{{workflow.parameters.repo}}"
```

### 6.3 Event coalescing (latest-SHA-wins)

- [ ] Configure Sensor **debounce / coalesce** so rapid pushes to `main` collapse to the **latest** `sha` per repo before Workflow creation (or drop superseded queued runs).
- [ ] Goal: when mutex releases, the next run uses the newest commit — not a stale intermediate SHA.

---

## 7. WorkflowTemplate — container, timeout, retry, volume

### 7.1 CRITICAL — workflow deadline

openwiki LLM latency is **unbounded**; the stage has **no internal timeout** by design. The cluster must enforce bounds:

- [ ] Set Workflow **`activeDeadlineSeconds`** (workflow-level, e.g. `7200`–`14400` — tune after first prod runs).
- [ ] Set **`retryStrategy`** with a small limit (spec: bounded retry for clone/R2; **at most one retry** for LLM/openwiki path, then fail).
- [ ] On deadline exceeded → Workflow Failed → notify (§10).

Example (**goes in olympus-gitops**):

```yaml
spec:
  activeDeadlineSeconds: 10800  # 3h — adjust operationally
  retryStrategy:
    limit: 1
    retryPolicy: Always
  templates:
    - name: codebase-brain-run
      synchronization:
        mutex:
          name: "brain-{{workflow.parameters.owner}}-{{workflow.parameters.repo}}"
      container:
        image: ghcr.io/nwlnexus/codebase-brain:<tag>
        command: ["bun", "run", "src/index.ts"]
        args:
          - --owner
          - "{{workflow.parameters.owner}}"
          - --repo
          - "{{workflow.parameters.repo}}"
          - --sha
          - "{{workflow.parameters.sha}}"
          - --phase
          - all
        envFrom:
          - secretRef:
              name: codebase-brain-secrets
        volumeMounts:
          - name: work-root
            mountPath: /tmp/codebase-brain-job
  volumeClaimTemplates:
    - metadata:
        name: work-root
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 20Gi  # tune per repo sizes
```

### 7.2 Persistent volume for `work-root` (recommended)

Default CLI flag: `--work-root /tmp/codebase-brain-job`.

- [ ] Mount a PVC (or hostPath if single-node dev) at `/tmp/codebase-brain-job` so **git clone cache** and **gitnexus analyze cache** persist across runs for the same repo.
- [ ] Understand layout the mutex protects:
  - `repos/{owner}/{repo}/` — reused clone; `openwiki` mutates under here
  - `brain/{owner}/{repo}/` — clone of `second-brain` for PR publishing, scoped per source repo (not a single shared `brain/` dir) so concurrent jobs for different repos never race on the same checkout
  - `out/{owner}/{repo}/latest-digests.json` — local digests marker (dry-run / fallback)
- [ ] PVC can be **per-repo** (strongest isolation) or **shared** (mutex still required for concurrent safety on `repos/` subtree). Because the brain clone is now per-repo, a global brain-push mutex is unnecessary — the existing per-repo `brain-{owner}-{repo}` mutex already serializes everything that touches a given repo's `brain/{owner}/{repo}` dir.

---

## 8. Job phases and LLM skip gate

CLI: `--phase 1 | 2 | all` (default **`all`**).

| Phase | Behavior |
| --- | --- |
| **`1`** | Deterministic only: clone → repomix pack → gitnexus analyze → facets → syft SBOM → R2 graph tarball. **No** openwiki, inventory page, brain PR, or digests marker. |
| **`2`** / **`all`** | Runs phase 1 stages, then (unless skipped) openwiki narrative → normalize OKF → syft inventory page → brain PR to `second-brain`. **`2` and `all` are equivalent** in current Job code. |

**LLM skip gate** (phase 2 / all only):

- [ ] Job fetches previous digests from R2 key `graphs/{owner}/{repo}/latest-digests.json`.
- [ ] If `(packHash, graphDigest, sbomDigest, templateVersion)` unchanged vs marker, openwiki is **skipped** (logs `skip LLM: digests unchanged`); brain PR step is also skipped.
- [ ] `latest-digests.json` is written locally and to R2 **only** after openwiki + normalize + inventory + brain PR succeed (phase `2`/`all` success path). `--phase 1` does not write the marker; skip path (unchanged digests) does not rewrite it. Local dry-run of `--phase all` still writes the local marker so a second dry-run can skip.

Operational split (optional):

- [ ] **Fast path:** `--phase 1` WorkflowTemplate variant for graph-only refreshes (no Anthropic spend).
- [ ] **Default prod:** `--phase all` on push-to-main.

R2 keys (bucket default `nwl-codebase-brain`, prefix `graphs`):

```text
graphs/{owner}/{repo}/{sha}.tgz      # immutable graph tarball
graphs/{owner}/{repo}/latest         # rolling tarball pointer
graphs/{owner}/{repo}/latest.json    # GraphRef JSON
graphs/{owner}/{repo}/latest-digests.json  # skip-gate marker
```

---

## 9. Brain PR target (never auto-merge)

- [ ] Target repo: **`second-brain`** (CLI default `--brain-repo second-brain`; slug `nwlnexus/second-brain`).
- [ ] Branch per source repo: **`automation/brain-{repo}`** (e.g. `automation/brain-moneta`).
- [ ] Content path: `docs/codebases/{repo}/` (+ `_meta/` for SBOM/facet/graph-ref artifacts).
- [ ] Job opens or updates PR via `gh`; PR body states **“Do not auto-merge.”**
- [ ] **Do not** configure auto-merge, merge queues, or bot-merge labels on these PRs.
- [ ] `GH_TOKEN` (from GitHub App install token via ExternalSecrets/1Password) must allow push to `automation/brain-*` branches and PR create/edit on `second-brain`.

---

## 10. Observability and failure surfacing

- [ ] Workflow status visible in Argo Workflows UI / `kubectl get workflows -n codebase-brain`.
- [ ] Pod logs include stage progress (`clone`, pack hash, graph digest, `skip LLM`, PR URL).
- [ ] On Workflow **Failed** or **Error** (including `activeDeadlineSeconds` exceeded): notify via Slack webhook ExternalSecret (reuse mnemosyne / existing notify patterns if available).
- [ ] Failed runs retain `{work-root}/out/{owner}/{repo}/{sha}/` artifacts on the PVC for debugging.
- [ ] Alert on repeated failures for the same repo (optional Prometheus / Argo exit-code metrics).

---

## 11. Manual image smoke test (pre-cutover)

Run from any host with the built image and secrets — validates image + credentials before enabling the Sensor.

```bash
# Toolchain smoke (no secrets)
podman run --rm ghcr.io/nwlnexus/codebase-brain:<tag> \
  sh -c 'which bun git tar syft repomix gitnexus openwiki'

# Phase 1 only (R2 creds required for upload)
podman run --rm \
  -e AWS_ENDPOINT_URL -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e BRAIN_R2_BUCKET \
  -v /tmp/cb-smoke:/tmp/codebase-brain-job \
  ghcr.io/nwlnexus/codebase-brain:<tag> \
  --owner nwlnexus --repo moneta --sha <full-sha> --phase 1

# Full pipeline (add Anthropic + GH_TOKEN)
podman run --rm \
  -e ANTHROPIC_API_KEY \
  -e AWS_ENDPOINT_URL -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e BRAIN_R2_BUCKET -e GH_TOKEN \
  -v /tmp/cb-smoke:/tmp/codebase-brain-job \
  ghcr.io/nwlnexus/codebase-brain:<tag> \
  --owner nwlnexus --repo moneta --sha <full-sha> --phase all
```

- [ ] Phase 1 smoke: R2 objects appear under `graphs/nwlnexus/<repo>/`.
- [ ] Phase all smoke: brain PR opened/updated on `nwlnexus/second-brain` branch `automation/brain-<repo>`.
- [ ] Re-run same SHA with unchanged tree: confirm `skip LLM: digests unchanged` when digests match.

---

## 12. Cutover verification

- [ ] Push to allowlisted repo `main` → Sensor fires → Workflow **Succeeded** for that SHA.
- [ ] Push to non-allowlisted repo → no Workflow created.
- [ ] Two rapid pushes to same repo → coalesced to latest SHA; mutex prevents overlapping pods.
- [ ] Mac launchd repomix sweep **disabled** before dual-writer period (separate cutover task).
- [ ] Document chosen registry tag, namespace, and webhook URL in olympus-gitops README.

---

## Appendix — brief vs build decisions

| Topic | Task brief | This checklist (build decisions) |
| --- | --- | --- |
| GitHub auth | “GitHub App creds” | Dedicated App; **1Password → ExternalSecrets** mint install token → Job `GH_TOKEN` (no personal PAT in prod) |
| Secrets source | (implied) | **1Password is source of truth**; ExternalSecrets syncs into the cluster — not sealed-secrets / ad-hoc kubectl secrets |
| Skip gate | (not in brief) | R2 **`latest-digests.json`** drives LLM skip |
| Timeout | (not in brief) | **`activeDeadlineSeconds`** required — openwiki has no internal timeout |
| Parent spec link | “link from parent spec §10” | Deferred to Task 14; spec §10 lists open choices (namespace, bucket, model pin) |
