# Repomix Pipeline — Design Spec

**Date:** 2026-07-12
**Status:** Approved for planning
**Scope:** Project 1 of 2. This spec covers the repomix context-pack pipeline and the durable install of both `repomix` and `gitnexus`. The second-brain architecture (where packs + the gitnexus graph flow into a cross-repo brain, and whether openwiki plays a role) is **Project 2** and is only referenced here as explicit seams.

---

## 1. Goal & Context

Produce an always-current, LLM-optimized **context pack** for each active repo, committed into the repo itself, and lay the groundwork for a cross-repo "second brain." The pack is machine-facing (fed to LLMs/agents), **not** human documentation.

### What already exists (do not rebuild)

| Layer | Tool | Role |
| --- | --- | --- |
| Memory | **moneta** (`mem.nwlnexus.io`, CF Worker + D1 + Vectorize + Workers AI) | Facts/decisions, shared across AI clients over MCP |
| Curated wiki | **Obsidian vault** (`~/Documents/Obsidian Vault/brain`) fed by **mnemosyne** + the `brain` skill | Human/LLM-authored prose knowledge |
| Code graph | **gitnexus** (`npx gitnexus`, MCP-queryable) | Structural relationships across repos — the cross-repo "relationships + patterns" engine |

### How the two evaluated tools fit

- **repomix** — deterministic, no-LLM, packs a whole repo into one file. Zero overlap with the above. Clean **add**. This project.
- **openwiki** (`langchain-ai/openwiki`) — an LLM CLI with connectors (git-repo, Notion, Gmail, web, HN) that synthesizes a wiki under `~/.openwiki/wiki/`. It is *not* a slot-in: it does not replace gitnexus (no graph/impact analysis) and where it is strong (multi-source aggregation) it competes with the existing mnemosyne→Obsidian→moneta loop. **Deferred to Project 2** as a re-architecture question, not adopted here.

### Delivery substrate (observed)

- `~/projects/{personal,work}`; `~/projects/personal` is a non-git container with a `.worktrees/` dir.
- **mise** is the nix-managed sole toolchain, declared in `nix-darwin-hm/home/default.nix` via `programs.mise`. `~/.config/mise/config.toml` is generated declaratively.
- SSH remote convention: `git@github.com:` (personal), `git@github.com-work:` (work, dtlr org).
- `gitnexus` is invoked as `npx gitnexus analyze`; it is **not** globally installed or nix-managed today.

---

## 2. Architecture

One home (`nix-darwin-hm`), two runners sharing one config and one pack format. Both runners operate on a **clean origin checkout — never a dev working clone.**

```
nix-darwin-hm/
├─ modules/repomix/repos.toml            # source of truth: grouped repo list
├─ modules/repomix/repomix.config.json   # shared repomix defaults
├─ modules/repomix/repomix.nix           # nix module: mise globals + PATH install + launchd
├─ scripts/repomix-pack/                 # Bun/TS local runner (fleet backfill + brain seam + notify)
│  ├─ index.ts
│  ├─ config.ts        checkout.ts       pack.ts
│  ├─ git-pr.ts        gitignore.ts      hash.ts
│  ├─ sink.ts          notify.ts
│  └─ *.test.ts
├─ .github/workflows/repomix-pack.yml    # reusable workflow (workflow_call) — per-repo freshness
└─ docs/superpowers/specs/2026-07-12-repomix-pipeline-design.md
```

### Division of labor (confirmed)

- **Per-repo pack freshness → CI on push.** One central reusable workflow in `nix-darwin-hm`; each target repo carries a tiny caller. Only CI sees every commit as it lands, so this is the freshness guarantee.
- **Fleet-wide backfill + the brain seam → local Bun runner.** On-demand + an optional nix-managed launchd schedule. The cross-repo brain (Project 2) is inherently a multi-repo job that CI-per-repo cannot build, so the local runner exists regardless.
- **Notification → Slack**, from both runners, on real changes only.

---

## 3. Configuration

### 3.1 `repos.toml` (source of truth)

```toml
[defaults]
pack_path = ".llm/repomix.xml"
branch    = "automation/repomix-pack"

[groups.personal]
base_dir = "~/projects/personal"
ssh_host = "github.com"
owner    = "nwlnexus"
repos    = ["olympus-sdk", "olympus-gitops", "olympus-infra", "nix-darwin-hm",
            "moneta", "nix-op-secrets", "second-brain", "olympus-tailnet", "homebrew-olympus"]

[groups.work]
base_dir = "~/projects/work"
ssh_host = "github.com-work"
owner    = "dtlr"
repos    = ["marquee", "drop-app"]
```

- Adding a group (e.g. `[groups.freelance]`) is a one-file edit → the extensibility requirement.
- Optional per-repo overrides via `[repo."owner/name"]` tables (keys: `pack_path`, `branch`, `ci` = false to exclude from CI rollout, `extra_ignore`).
- **Open confirmations at review:** the input list had `second-brain` and `homebrew-olympus` duplicated (deduped here). Confirm `nwlnexus/second-brain` is the real remote vs. `second-brain-cloudflare`/`moneta` (which are the local dir names).

### 3.2 `repomix.config.json` (shared pack defaults)

```jsonc
{
  "output": {
    "filePath": ".llm/repomix.xml",
    "style": "xml",              // most context-friendly for Claude; machine-facing
    "removeComments": false,
    "compress": false            // per-repo override for very large repos (e.g. olympus-sdk, 655 files)
  },
  "ignore": {
    "useGitignore": true,
    "useDefaultPatterns": true,
    "customPatterns": [".llm/**"] // prevents the pack from including its own prior output
  }
}
```

- A repo's own `repomix.config.json`, if present, is respected/merged (repomix native discovery) — repos can tune includes without editing the shared config.

---

## 4. Local Runner (`repomix-pack`, Bun/TS)

Bun chosen for: native TOML import, alignment with the TS-heavy stack (olympus-sdk, moneta), clean git/gh orchestration via Bun `$`, `bun test`. Bun is already a mise global.

### 4.1 Per-repo algorithm

1. **Resolve origin URL** from the group (`ssh_host`, `owner`, `name`).
2. **Isolated checkout at origin default branch** into `~/.cache/repomix-pipeline/<owner>/<name>`:
   - first run: `git clone --depth 1 <url> <cache>`;
   - later runs: `git fetch origin <default> --depth 1 && git reset --hard origin/<default> && git clean -fdx`.
   - The user's dev clones in `~/projects/**` are never read or written. This fully resolves the stale-clone / update-conflict hazard.
3. **Pack**: run `repomix` with the shared config → `<cache>/.llm/repomix.xml`, `.llm/` ignored.
4. **Change-gate**: compare the new pack's content hash to the pack currently committed on origin. Unchanged → skip (no branch, no PR, no notification).
5. **Guarantee tracked**: if `git check-ignore .llm/repomix.xml` matches, write a `!/.llm/` negation into the repo's `.gitignore` and stage the pack with `git add -f`.
6. **Deterministic branch → PR**: reset `automation/repomix-pack` to the base branch, commit the pack (+ any `.gitignore` fix), force-push, then create-or-update the single open PR via `gh`. Label `automation`. **Never auto-merge.**
7. **Brain seam**: call `sink(pack, meta)` (see §7).
8. **Notify**: on a created/updated PR, call `notify(prMeta)` (see §6).

### 4.2 CLI surface

```
repomix-pack [--group personal|work|all] [--only owner/name ...]
             [--dry-run] [--no-pr] [--brain-only] [--no-notify]
```

- Repos processed with a bounded concurrency pool.
- **Per-repo isolation**: one repo's failure (auth, missing repo, pack error) never aborts the sweep; it is recorded.
- **End-of-run summary**: table of `succeeded | skipped(unchanged) | failed` with PR URLs, printed and included in the batched Slack summary.

---

## 5. Reusable CI Workflow

### 5.1 Central workflow — `nix-darwin-hm/.github/workflows/repomix-pack.yml`

`on: workflow_call`. Steps:

1. `actions/checkout`.
2. Setup Node; run `npx repomix` with the shared config (config passed as a workflow input or fetched from `nix-darwin-hm` at a pinned ref).
3. Gitignore-guarantee (same rule as §4.1.5).
4. Change-gate (same hash rule).
5. `peter-evans/create-pull-request` — idempotent branch (`automation/repomix-pack`) + create-or-update PR, using the native `GITHUB_TOKEN` (no PAT for same-repo PRs). Label `automation`.
6. Slack notify step on change (webhook secret from repo/org secrets).

`concurrency: group=repomix-pack, cancel-in-progress=true`.

### 5.2 Per-repo caller — `.github/workflows/pack.yml` (3 lines of intent)

```yaml
on:
  push: { branches: [<default>], paths-ignore: [".llm/**"] }  # pack commit never re-triggers
  workflow_dispatch:
jobs:
  pack:
    uses: nwlnexus/nix-darwin-hm/.github/workflows/repomix-pack.yml@main
    secrets: inherit
```

- **One-time setup**: enable private-repo reusable-workflow access in `nix-darwin-hm` → Settings → Actions (so callers can reference it).
- **Work/dtlr repos** may be excluded from CI by org policy (`ci = false` in `repos.toml`); they rely on the local sweep.

---

## 6. Notification (Slack)

Replaces auto-merge — you review, but you are told.

- **Trigger**: only when the change-gate fired and a PR was created/updated (piggybacks the hash gate → no spam).
- **Mechanism**: Slack **Incoming Webhook**, identical for both runners.
  - Secret: 1Password `op://Dev/repomix-pipeline/slack_webhook` (matches the existing secret pattern); local runner reads via `op`, CI reads from repo/org secrets.
- **Channel**: proposed `#automation-prs` (confirm name at review).
- **Payload**: repo, base branch, pack delta (files/token-count change), PR URL. Local fleet sweep sends one message per changed repo (or a single batched summary block).

---

## 7. Brain Seam (Project 2 stub)

The runner exposes a single seam so Project 2 can wire a real destination without touching the pipeline:

```ts
// sink.ts
export interface PackSink {
  write(pack: PackArtifact, meta: RepoMeta): Promise<void>;
}
```

- **Default impl (this project)**: `StagingSink` writes the pack + a JSON manifest (owner, name, commit, hash, timestamp) to `~/.cache/repomix-pipeline/brain-staging/<owner>/<name>.{xml,json}`.
- **Project 2 seams noted, not built**: (a) real sink target (Obsidian / moneta / gitnexus / openwiki — TBD by the brain spec); (b) gitnexus **index freshness + shared graph state** (today per-machine and stale — `marquee` 251 commits behind, `drop-app` 153); (c) the synergy where the same push/sweep trigger also runs `gitnexus analyze` so the graph stops drifting.

---

## 8. Nix Wiring (durability & portability)

All in `nix-darwin-hm`, so every nix-managed host inherits it:

1. **Global tools** via `programs.mise` global config:
   - `"npm:repomix"` — the packer.
   - `"npm:gitnexus"` — replaces ad-hoc `npx gitnexus`; **install durability only** (state/refresh is Project 2).
2. **Runner on PATH**: `pkgs.writeShellApplication` named `repomix-pack` that execs `bun <path-to>/scripts/repomix-pack/index.ts`, with `bun`, `git`, `gh`, `_1password-cli` in its runtime inputs.
3. **Schedule**: `launchd.user.agents.repomix-pack` runs `repomix-pack --group all` on a calendar interval (e.g. daily 09:00), as the fleet safety-net + brain refresh. `RunAtLoad = false`.

---

## 9. Error Handling

- **Per-repo isolation** in the local sweep; end-of-run non-zero exit only if ≥1 repo failed, with a clear summary.
- **Auth failures** (SSH / gh / op) surfaced explicitly, repo skipped, not fatal to the sweep.
- **Missing repo / no access** → warn + skip.
- **Empty/noisy PRs** prevented by the change-gate.
- **Cross-host / CI-vs-local races** avoided by: one deterministic branch + create-or-update semantics + content-hash gate. CI is the authority; a local run whose pack already matches origin no-ops.
- **Self-inclusion loop** prevented by `.llm/**` ignore (pack) + `paths-ignore: .llm/**` (CI trigger).

---

## 10. Testing

- **Unit** (`bun test`): TOML/config parsing; change-gate hashing; gitignore-negation logic; branch/PR create-or-update idempotency (git + gh mocked); Slack payload formatting.
- **Integration**: full local run against a throwaway sandbox repo — verifies checkout isolation, pack write, tracked-guarantee, PR create then update, and no-op on unchanged.
- **CI**: pilot the reusable workflow on `olympus-sdk` (validate `paths-ignore`, PR idempotency, notification) before fan-out.

---

## 11. Rollout Order

1. Nix: add `repomix` + `gitnexus` mise globals, shared config, runner PATH install, launchd agent.
2. Local runner MVP: config → isolated checkout → pack → tracked-guarantee → PR, on the `personal` group.
3. Add change-gate, `.gitignore` negation, brain `StagingSink`, Slack notify.
4. Reusable workflow + caller on `olympus-sdk` (pilot).
5. Fan callers out to remaining personal repos.
6. Work group (`marquee`, `drop-app`) via the local sweep (CI excluded per org policy).

---

## 12. Explicitly Out of Scope (→ Project 2)

- Where packs and the gitnexus graph ultimately flow to build the second brain.
- gitnexus shared-graph state and re-analyze-on-change freshness.
- openwiki adoption / rejection and any brain re-architecture.
- Replacing or retiring mnemosyne / Obsidian / moneta.
