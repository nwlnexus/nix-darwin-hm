# Repomix Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a durable, nix-managed pipeline that generates an LLM-optimized repomix "context pack" for each active repo, commits it via PR, notifies Slack, and lays a pluggable seam for a future cross-repo second brain.

**Architecture:** One home (`nix-darwin-hm`) hosts a shared config, a Bun/TS local runner (fleet backfill on clean origin checkouts + brain seam), and a reusable CI workflow (per-repo push-time freshness). Both runners share `repos.toml` + `repomix.config.json`, write `.llm/repomix.xml`, gate on a content hash, use one deterministic branch, and never auto-merge.

**Tech Stack:** Nix (nix-darwin + home-manager, `programs.mise`, `launchd`), mise globals (`npm:repomix`, `npm:gitnexus`), Bun/TypeScript, `git`, `gh`, `_1password-cli` (`op`), GitHub Actions (`workflow_call`, `peter-evans/create-pull-request`), Slack Incoming Webhook.

**Spec:** [`docs/superpowers/specs/2026-07-12-repomix-pipeline-design.md`](../specs/2026-07-12-repomix-pipeline-design.md)

**Epic:** [nwlnexus/nix-darwin-hm#9](https://github.com/nwlnexus/nix-darwin-hm/issues/9) — all tasks below are native sub-issues (#10–#22) of this epic.

## Global Constraints

- Runner language: **Bun/TypeScript** (Bun is already a mise global). Test with `bun test`.
- Pack path (default): `.llm/repomix.xml`; format `xml`; ignore `.llm/**` in every pack.
- Deterministic PR branch (default): `automation/repomix-pack`. **Never auto-merge.**
- The runner operates **only** on pipeline-owned checkouts under `~/.cache/repomix-pipeline/`; it must never read or write a dev clone under `~/projects/**`.
- Config source of truth: `modules/repomix/repos.toml`. Adding a group is a one-file edit.
- Secrets via 1Password only: Slack webhook at `op://Dev/repomix-pipeline/slack_webhook`.
- SSH host convention: `github.com` (personal, owner `nwlnexus`), `github.com-work` (work, owner `dtlr`).
- Notifications and PRs fire **only** when the content-hash change-gate trips (no empty PRs, no Slack spam).
- gitnexus: **install durability only** (mise global). Graph state/refresh is Project 2 — do not build it here.

---

## Tracking Protocol (REQUIRED — keep in sync)

This work is tracked in **both** this plan file and GitHub issues. Neither is authoritative alone; keep them consistent.

- **Epic issue:** the parent tracks the whole pipeline. Each task below maps to a **native GitHub sub-issue** of the epic (see the Ticket Map).
- **On starting a task:** check the task's first `- [ ]` here, set the sub-issue to in-progress (assign yourself / add `status:in-progress` label), and comment the branch/worktree you are using.
- **On finishing a task:** check every `- [ ]` step here, comment the merged PR/commit SHA on the sub-issue, and **close the sub-issue**. GitHub auto-updates the epic's sub-issue progress bar.
- **Cross-linking:** every sub-issue body links back to this plan and its task heading; this plan's Ticket Map links each task to its sub-issue. PRs must reference their sub-issue (`Closes #<n>`).
- **Progress source of truth for humans:** the epic issue's sub-issue checklist. Keep the plan checkboxes matching it.

### Ticket Map

| Task | Sub-issue | Depends on | Parallel group |
| --- | --- | --- | --- |
| 1. Nix globals + config scaffolding | [#10](https://github.com/nwlnexus/nix-darwin-hm/issues/10) | — | A |
| 2. Runner scaffold + config parser | [#11](https://github.com/nwlnexus/nix-darwin-hm/issues/11) | 1 | B |
| 3. Isolated origin checkout | [#12](https://github.com/nwlnexus/nix-darwin-hm/issues/12) | 2 | B |
| 4. Pack + content-hash gate | [#13](https://github.com/nwlnexus/nix-darwin-hm/issues/13) | 2 | B |
| 5. Gitignore-guarantee | [#14](https://github.com/nwlnexus/nix-darwin-hm/issues/14) | 2 | B |
| 6. Branch → PR create-or-update | [#15](https://github.com/nwlnexus/nix-darwin-hm/issues/15) | 2 | B |
| 7. Brain sink stub (StagingSink) | [#16](https://github.com/nwlnexus/nix-darwin-hm/issues/16) | 2 | B |
| 8. Slack notify | [#17](https://github.com/nwlnexus/nix-darwin-hm/issues/17) | 2 | B |
| 9. Runner orchestration + CLI | [#18](https://github.com/nwlnexus/nix-darwin-hm/issues/18) | 3,4,5,6,7,8 | C |
| 10. Reusable CI workflow | [#19](https://github.com/nwlnexus/nix-darwin-hm/issues/19) | 1 | A |
| 11. Pilot caller on olympus-sdk | [#20](https://github.com/nwlnexus/nix-darwin-hm/issues/20) | 10 | D |
| 12. Nix PATH install + launchd | [#21](https://github.com/nwlnexus/nix-darwin-hm/issues/21) | 9 | D |
| 13. Fan-out callers + work sweep | [#22](https://github.com/nwlnexus/nix-darwin-hm/issues/22) | 11,12 | E |

---

## Parallelization Strategy (preferred wherever possible)

Parallelize aggressively. The dependency graph is intentionally shallow so multiple workers (or subagents) run concurrently.

- **Group A (start immediately, independent):** Task 1 (nix globals + config) and Task 10 (reusable CI workflow) share no files and can proceed in parallel from the outset.
- **Group B (fan-out, after Task 2):** Once the config parser and its `RepoTarget` interface exist (Task 2), Tasks 3–8 are **independent modules** consuming that interface. Dispatch them in parallel — they touch disjoint files (`checkout.ts`, `pack.ts`/`hash.ts`, `gitignore.ts`, `git-pr.ts`, `sink.ts`, `notify.ts`) and each has its own test file.
- **Group C (join):** Task 9 wires Group B together; it is the single synchronization point.
- **Group D (parallel):** Task 11 (CI pilot) and Task 12 (nix PATH + launchd) are independent once their prerequisites land.
- **Group E:** Task 13 fan-out, last.

When executing with subagents, launch each parallel group as a single batch of concurrent dispatches. Only serialize across group boundaries. Record in each sub-issue which group/batch it ran in.

---

## File Structure

- `home/default.nix` — **modify**: add `npm:repomix` + `npm:gitnexus` to `programs.mise` global tools.
- `modules/repomix/repos.toml` — **create**: grouped repo list (source of truth).
- `modules/repomix/repomix.config.json` — **create**: shared pack defaults.
- `modules/repomix/repomix.nix` — **create**: nix module (PATH install of the runner + launchd agent).
- `scripts/repomix-pack/package.json` — **create**: Bun project manifest.
- `scripts/repomix-pack/tsconfig.json` — **create**.
- `scripts/repomix-pack/src/types.ts` — **create**: shared interfaces.
- `scripts/repomix-pack/src/config.ts` — **create**: parse `repos.toml` → `RepoTarget[]`.
- `scripts/repomix-pack/src/checkout.ts` — **create**: isolated origin checkout.
- `scripts/repomix-pack/src/hash.ts` — **create**: content hash helper.
- `scripts/repomix-pack/src/pack.ts` — **create**: run repomix + gate.
- `scripts/repomix-pack/src/gitignore.ts` — **create**: tracked-guarantee.
- `scripts/repomix-pack/src/git-pr.ts` — **create**: branch + PR create-or-update.
- `scripts/repomix-pack/src/sink.ts` — **create**: `PackSink` + `StagingSink`.
- `scripts/repomix-pack/src/notify.ts` — **create**: Slack webhook.
- `scripts/repomix-pack/src/index.ts` — **create**: CLI + orchestration.
- `.github/workflows/repomix-pack.yml` — **create**: reusable workflow.

Test files live beside their module as `*.test.ts`.

---

## Task 1: Nix globals + config scaffolding

**Files:**
- Modify: `home/default.nix` (the `programs.mise` block, ~line 206)
- Create: `modules/repomix/repos.toml`
- Create: `modules/repomix/repomix.config.json`

**Interfaces:**
- Produces: `modules/repomix/repos.toml` (schema below) and `modules/repomix/repomix.config.json`, consumed by Tasks 2 and 10. `repomix` + `gitnexus` on `PATH` after rebuild.

- [ ] **Step 1: Add mise globals.** In `home/default.nix`, inside `programs.mise` `globalConfig.tools`, add:

```nix
"npm:repomix" = "latest";
"npm:gitnexus" = "latest";
```

- [ ] **Step 2: Create `modules/repomix/repos.toml`:**

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

- [ ] **Step 3: Create `modules/repomix/repomix.config.json`:**

```json
{
  "output": {
    "filePath": ".llm/repomix.xml",
    "style": "xml",
    "removeComments": false,
    "compress": false
  },
  "ignore": {
    "useGitignore": true,
    "useDefaultPatterns": true,
    "customPatterns": [".llm/**"]
  }
}
```

- [ ] **Step 4: Verify the flake evaluates.**

Run: `nix flake check ~/projects/personal/nix-darwin-hm 2>&1 | tail -5` (or `darwin-rebuild build --flake .#$(hostname -s)` for the active host)
Expected: evaluation succeeds; no error referencing `programs.mise` or `modules/repomix`.

- [ ] **Step 5: Commit.**

```bash
git add home/default.nix modules/repomix/repos.toml modules/repomix/repomix.config.json
git commit -m "feat(repomix): mise globals + shared config scaffolding (#<ticket>)"
```

---

## Task 2: Runner scaffold + config parser

**Files:**
- Create: `scripts/repomix-pack/package.json`, `tsconfig.json`
- Create: `scripts/repomix-pack/src/types.ts`
- Create: `scripts/repomix-pack/src/config.ts`
- Test: `scripts/repomix-pack/src/config.test.ts`

**Interfaces:**
- Consumes: `modules/repomix/repos.toml` (Task 1).
- Produces:
  - `types.ts`: `interface RepoTarget { owner: string; name: string; slug: string; sshHost: string; originUrl: string; defaultBranch: string | null; packPath: string; branch: string; group: string; }`
  - `config.ts`: `loadTargets(tomlPath: string, opts?: { group?: string; only?: string[] }): RepoTarget[]`

- [ ] **Step 1: Scaffold the Bun project.** Create `scripts/repomix-pack/package.json`:

```json
{
  "name": "repomix-pack",
  "type": "module",
  "private": true,
  "scripts": { "test": "bun test", "start": "bun run src/index.ts" }
}
```

Create `scripts/repomix-pack/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["bun-types"],
    "strict": true,
    "skipLibCheck": true
  }
}
```

- [ ] **Step 2: Define `src/types.ts`:**

```ts
export interface RepoTarget {
  owner: string;
  name: string;
  slug: string;          // `${owner}/${name}`
  sshHost: string;
  originUrl: string;     // git@${sshHost}:${owner}/${name}.git
  defaultBranch: string | null; // resolved lazily at checkout
  packPath: string;
  branch: string;
  group: string;
}
```

- [ ] **Step 3: Write the failing test** `src/config.test.ts`:

```ts
import { test, expect } from "bun:test";
import { loadTargets } from "./config";
import { writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const TOML = `
[defaults]
pack_path = ".llm/repomix.xml"
branch = "automation/repomix-pack"

[groups.personal]
base_dir = "~/projects/personal"
ssh_host = "github.com"
owner = "nwlnexus"
repos = ["olympus-sdk", "moneta"]

[groups.work]
base_dir = "~/projects/work"
ssh_host = "github.com-work"
owner = "dtlr"
repos = ["marquee"]
`;

function fixture(): string {
  const dir = mkdtempSync(join(tmpdir(), "repos-"));
  const p = join(dir, "repos.toml");
  writeFileSync(p, TOML);
  return p;
}

test("loads all targets with derived fields", () => {
  const targets = loadTargets(fixture());
  expect(targets.length).toBe(3);
  const sdk = targets.find((t) => t.name === "olympus-sdk")!;
  expect(sdk.slug).toBe("nwlnexus/olympus-sdk");
  expect(sdk.originUrl).toBe("git@github.com:nwlnexus/olympus-sdk.git");
  expect(sdk.packPath).toBe(".llm/repomix.xml");
  expect(sdk.branch).toBe("automation/repomix-pack");
});

test("filters by group", () => {
  const targets = loadTargets(fixture(), { group: "work" });
  expect(targets.map((t) => t.slug)).toEqual(["dtlr/marquee"]);
  expect(targets[0].sshHost).toBe("github.com-work");
});

test("filters by explicit slug list", () => {
  const targets = loadTargets(fixture(), { only: ["nwlnexus/moneta"] });
  expect(targets.map((t) => t.slug)).toEqual(["nwlnexus/moneta"]);
});
```

- [ ] **Step 4: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/config.test.ts`
Expected: FAIL — `loadTargets` not found / module has no export.

- [ ] **Step 5: Implement `src/config.ts`:**

```ts
import { RepoTarget } from "./types";

interface Toml {
  defaults?: { pack_path?: string; branch?: string };
  groups?: Record<string, { ssh_host: string; owner: string; repos: string[] }>;
  repo?: Record<string, { pack_path?: string; branch?: string; ci?: boolean }>;
}

export function loadTargets(
  tomlPath: string,
  opts: { group?: string; only?: string[] } = {},
): RepoTarget[] {
  // Bun parses TOML natively via import assertion.
  const cfg = require(tomlPath) as Toml;
  const packDefault = cfg.defaults?.pack_path ?? ".llm/repomix.xml";
  const branchDefault = cfg.defaults?.branch ?? "automation/repomix-pack";
  const only = opts.only ? new Set(opts.only) : null;

  const out: RepoTarget[] = [];
  for (const [group, g] of Object.entries(cfg.groups ?? {})) {
    if (opts.group && opts.group !== group) continue;
    for (const name of g.repos) {
      const slug = `${g.owner}/${name}`;
      if (only && !only.has(slug)) continue;
      const override = cfg.repo?.[slug] ?? {};
      out.push({
        owner: g.owner,
        name,
        slug,
        sshHost: g.ssh_host,
        originUrl: `git@${g.ssh_host}:${g.owner}/${name}.git`,
        defaultBranch: null,
        packPath: override.pack_path ?? packDefault,
        branch: override.branch ?? branchDefault,
        group,
      });
    }
  }
  return out;
}
```

> Note: Bun supports `require()`/`import` of `.toml` files natively. If the pinned Bun version does not, add `bun-plugin-toml` or parse with `@iarna/toml`; the test asserts behavior, not mechanism.

- [ ] **Step 6: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/config.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit.**

```bash
git add scripts/repomix-pack/package.json scripts/repomix-pack/tsconfig.json \
        scripts/repomix-pack/src/types.ts scripts/repomix-pack/src/config.ts \
        scripts/repomix-pack/src/config.test.ts
git commit -m "feat(repomix): config parser + RepoTarget (#<ticket>)"
```

---

## Task 3: Isolated origin checkout

**Files:**
- Create: `scripts/repomix-pack/src/checkout.ts`
- Test: `scripts/repomix-pack/src/checkout.test.ts`

**Interfaces:**
- Consumes: `RepoTarget` (Task 2).
- Produces: `checkout(target: RepoTarget, cacheRoot: string): Promise<{ dir: string; defaultBranch: string; headSha: string }>`

- [ ] **Step 1: Write the failing test** `src/checkout.test.ts` (uses a local bare repo as a fake origin so no network):

```ts
import { test, expect } from "bun:test";
import { checkout } from "./checkout";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

async function fakeOrigin(): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "origin-"));
  const work = join(dir, "work");
  mkdirSync(work);
  await $`git -C ${work} init -q -b main`;
  writeFileSync(join(work, "README.md"), "hello");
  await $`git -C ${work} add -A`;
  await $`git -C ${work} -c user.email=t@t -c user.name=t commit -qm init`;
  const bare = join(dir, "origin.git");
  await $`git clone -q --bare ${work} ${bare}`;
  return bare;
}

test("clones origin into cache and reports head", async () => {
  const origin = await fakeOrigin();
  const cacheRoot = mkdtempSync(join(tmpdir(), "cache-"));
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget",
    sshHost: "github.com", originUrl: origin, defaultBranch: null,
    packPath: ".llm/repomix.xml", branch: "automation/repomix-pack", group: "personal",
  };
  const res = await checkout(target as any, cacheRoot);
  expect(res.defaultBranch).toBe("main");
  expect(res.headSha).toMatch(/^[0-9a-f]{40}$/);
  expect(await Bun.file(join(res.dir, "README.md")).text()).toBe("hello");
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/checkout.test.ts`
Expected: FAIL — `checkout` not found.

- [ ] **Step 3: Implement `src/checkout.ts`:**

```ts
import { $ } from "bun";
import { RepoTarget } from "./types";
import { existsSync } from "node:fs";
import { join } from "node:path";

export async function checkout(
  target: RepoTarget,
  cacheRoot: string,
): Promise<{ dir: string; defaultBranch: string; headSha: string }> {
  const dir = join(cacheRoot, target.owner, target.name);
  // Resolve origin's default branch without a full clone.
  const headRef = (await $`git ls-remote --symref ${target.originUrl} HEAD`.text())
    .split("\n")[0];
  const m = headRef.match(/ref:\s+refs\/heads\/(\S+)\s+HEAD/);
  const defaultBranch = m ? m[1] : "main";

  if (!existsSync(join(dir, ".git"))) {
    await $`git clone --depth 1 --branch ${defaultBranch} ${target.originUrl} ${dir}`.quiet();
  } else {
    await $`git -C ${dir} fetch --depth 1 origin ${defaultBranch}`.quiet();
    await $`git -C ${dir} reset --hard origin/${defaultBranch}`.quiet();
    await $`git -C ${dir} clean -fdx`.quiet();
  }
  const headSha = (await $`git -C ${dir} rev-parse HEAD`.text()).trim();
  return { dir, defaultBranch, headSha };
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/checkout.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add scripts/repomix-pack/src/checkout.ts scripts/repomix-pack/src/checkout.test.ts
git commit -m "feat(repomix): isolated origin checkout (#<ticket>)"
```

---

## Task 4: Pack + content-hash gate

**Files:**
- Create: `scripts/repomix-pack/src/hash.ts`, `src/pack.ts`
- Test: `scripts/repomix-pack/src/pack.test.ts`

**Interfaces:**
- Consumes: `RepoTarget`, checkout `dir` (Task 3).
- Produces:
  - `hash.ts`: `contentHash(bytes: Uint8Array | string): string` (sha256 hex)
  - `pack.ts`: `runPack(dir: string, configPath: string): Promise<void>` and `packChanged(dir: string, packPath: string): Promise<{ changed: boolean; newHash: string; bytes: number }>`

- [ ] **Step 1: Write the failing test** `src/pack.test.ts`:

```ts
import { test, expect } from "bun:test";
import { contentHash } from "./hash";
import { packChanged } from "./pack";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("contentHash is stable and sensitive", () => {
  expect(contentHash("a")).toBe(contentHash("a"));
  expect(contentHash("a")).not.toBe(contentHash("b"));
});

test("packChanged true when committed pack differs, false when identical", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "OLD");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c user.email=t@t -c user.name=t commit -qm base`;

  // New pack content differs from committed "OLD".
  writeFileSync(join(dir, ".llm/repomix.xml"), "NEW");
  const changed = await packChanged(dir, ".llm/repomix.xml");
  expect(changed.changed).toBe(true);
  expect(changed.bytes).toBe(3);

  // Rewrite identical to committed -> after committing NEW, no change.
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c user.email=t@t -c user.name=t commit -qm new`;
  const same = await packChanged(dir, ".llm/repomix.xml");
  expect(same.changed).toBe(false);
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/pack.test.ts`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement `src/hash.ts`:**

```ts
import { createHash } from "node:crypto";

export function contentHash(bytes: Uint8Array | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}
```

- [ ] **Step 4: Implement `src/pack.ts`:**

```ts
import { $ } from "bun";
import { join } from "node:path";
import { contentHash } from "./hash";

export async function runPack(dir: string, configPath: string): Promise<void> {
  // repomix writes to the config's output.filePath (.llm/repomix.xml).
  await $`repomix --config ${configPath} ${dir}`.cwd(dir).quiet();
}

export async function packChanged(
  dir: string,
  packPath: string,
): Promise<{ changed: boolean; newHash: string; bytes: number }> {
  const newBytes = await Bun.file(join(dir, packPath)).arrayBuffer();
  const newHash = contentHash(new Uint8Array(newBytes));
  // Committed version on the checked-out (origin) HEAD.
  const committed = await $`git -C ${dir} show HEAD:${packPath}`.quiet().nothrow();
  const changed =
    committed.exitCode !== 0 || contentHash(committed.stdout) !== newHash;
  return { changed, newHash, bytes: newBytes.byteLength };
}
```

- [ ] **Step 5: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/pack.test.ts`
Expected: PASS (2 tests). (`runPack` is exercised in the Task 9 integration test, which requires the real `repomix` binary.)

- [ ] **Step 6: Commit.**

```bash
git add scripts/repomix-pack/src/hash.ts scripts/repomix-pack/src/pack.ts scripts/repomix-pack/src/pack.test.ts
git commit -m "feat(repomix): pack runner + content-hash change gate (#<ticket>)"
```

---

## Task 5: Gitignore-guarantee

**Files:**
- Create: `scripts/repomix-pack/src/gitignore.ts`
- Test: `scripts/repomix-pack/src/gitignore.test.ts`

**Interfaces:**
- Produces: `ensureTracked(dir: string, packPath: string): Promise<{ patched: boolean }>` — guarantees `packPath` is not gitignored, writing a `!/<dir>/` negation to `.gitignore` if needed.

- [ ] **Step 1: Write the failing test** `src/gitignore.test.ts`:

```ts
import { test, expect } from "bun:test";
import { ensureTracked } from "./gitignore";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("adds negation when pack dir is ignored", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  writeFileSync(join(dir, ".gitignore"), ".llm/\n");
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "x");

  const res = await ensureTracked(dir, ".llm/repomix.xml");
  expect(res.patched).toBe(true);
  expect(readFileSync(join(dir, ".gitignore"), "utf8")).toContain("!/.llm/");

  const ck = await $`git -C ${dir} check-ignore .llm/repomix.xml`.nothrow().quiet();
  expect(ck.exitCode).not.toBe(0); // no longer ignored
});

test("no-op when already tracked", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "x");
  const res = await ensureTracked(dir, ".llm/repomix.xml");
  expect(res.patched).toBe(false);
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/gitignore.test.ts`
Expected: FAIL — `ensureTracked` not found.

- [ ] **Step 3: Implement `src/gitignore.ts`:**

```ts
import { $ } from "bun";
import { join, dirname } from "node:path";
import { appendFileSync, existsSync, readFileSync } from "node:fs";

export async function ensureTracked(
  dir: string,
  packPath: string,
): Promise<{ patched: boolean }> {
  const ck = await $`git -C ${dir} check-ignore ${packPath}`.nothrow().quiet();
  if (ck.exitCode !== 0) return { patched: false }; // not ignored
  const negation = `!/${dirname(packPath)}/`;
  const giPath = join(dir, ".gitignore");
  const existing = existsSync(giPath) ? readFileSync(giPath, "utf8") : "";
  if (!existing.split("\n").includes(negation)) {
    appendFileSync(giPath, `\n# repomix pipeline: keep context pack tracked\n${negation}\n`);
  }
  return { patched: true };
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/gitignore.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit.**

```bash
git add scripts/repomix-pack/src/gitignore.ts scripts/repomix-pack/src/gitignore.test.ts
git commit -m "feat(repomix): guarantee pack stays git-tracked (#<ticket>)"
```

---

## Task 6: Branch → PR create-or-update

**Files:**
- Create: `scripts/repomix-pack/src/git-pr.ts`
- Test: `scripts/repomix-pack/src/git-pr.test.ts`

**Interfaces:**
- Consumes: checkout `dir`, `RepoTarget`.
- Produces: `commitToBranch(dir: string, target: RepoTarget, base: string, files: string[]): Promise<void>` (deterministic branch, reset to base, commit, force-push) and `openOrUpdatePr(target: RepoTarget, base: string, title: string, body: string): Promise<{ url: string; created: boolean }>` (idempotent via `gh`).

The push/PR calls are shelled to `git`/`gh`; the local test covers the branch/commit mechanics against a bare origin (no `gh`). PR idempotency is covered by the Task 11 CI pilot.

- [ ] **Step 1: Write the failing test** `src/git-pr.test.ts`:

```ts
import { test, expect } from "bun:test";
import { commitToBranch } from "./git-pr";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("commits pack to deterministic branch and pushes to origin", async () => {
  const root = mkdtempSync(join(tmpdir(), "gp-"));
  const bare = join(root, "origin.git");
  await $`git init -q --bare ${bare}`;
  const dir = join(root, "clone");
  await $`git clone -q ${bare} ${dir}`;
  await $`git -C ${dir} config user.email t@t`;
  await $`git -C ${dir} config user.name t`;
  writeFileSync(join(dir, "seed"), "1");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} commit -qm seed`;
  await $`git -C ${dir} push -q origin HEAD:main`;

  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget", sshHost: "github.com",
    originUrl: bare, defaultBranch: "main", packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack", group: "personal",
  };
  await commitToBranch(dir, target as any, "main", [".llm/repomix.xml"]);

  const branches = await $`git -C ${bare} branch --format=%(refname:short)`.text();
  expect(branches).toContain("automation/repomix-pack");
  const show = await $`git -C ${bare} show automation/repomix-pack:.llm/repomix.xml`.text();
  expect(show.trim()).toBe("PACK");
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/git-pr.test.ts`
Expected: FAIL — `commitToBranch` not found.

- [ ] **Step 3: Implement `src/git-pr.ts`:**

```ts
import { $ } from "bun";
import { RepoTarget } from "./types";

export async function commitToBranch(
  dir: string,
  target: RepoTarget,
  base: string,
  files: string[],
): Promise<void> {
  await $`git -C ${dir} checkout -B ${target.branch} ${base}`.quiet();
  for (const f of files) await $`git -C ${dir} add -f ${f}`.quiet();
  await $`git -C ${dir} -c user.email=repomix-bot@nwlnexus.io -c user.name=repomix-pipeline commit -qm ${"chore: refresh repomix context pack"}`.quiet();
  await $`git -C ${dir} push -f origin ${target.branch}`.quiet();
}

export async function openOrUpdatePr(
  target: RepoTarget,
  base: string,
  title: string,
  body: string,
): Promise<{ url: string; created: boolean }> {
  const existing = await $`gh pr list --repo ${target.slug} --head ${target.branch} --state open --json url --jq ".[0].url"`
    .quiet().nothrow();
  const url0 = existing.stdout.toString().trim();
  if (url0) {
    await $`gh pr edit ${url0} --title ${title} --body ${body}`.quiet().nothrow();
    return { url: url0, created: false };
  }
  const created = await $`gh pr create --repo ${target.slug} --base ${base} --head ${target.branch} --title ${title} --body ${body} --label automation`.text();
  return { url: created.trim(), created: true };
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/git-pr.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add scripts/repomix-pack/src/git-pr.ts scripts/repomix-pack/src/git-pr.test.ts
git commit -m "feat(repomix): deterministic branch + idempotent PR (#<ticket>)"
```

---

## Task 7: Brain sink stub (StagingSink)

**Files:**
- Create: `scripts/repomix-pack/src/sink.ts`
- Test: `scripts/repomix-pack/src/sink.test.ts`

**Interfaces:**
- Produces:
  - `interface RepoMeta { slug: string; owner: string; name: string; commit: string; hash: string; bytes: number; ts: string; }`
  - `interface PackSink { write(packBytes: Uint8Array, meta: RepoMeta): Promise<void>; }`
  - `class StagingSink implements PackSink` — writes `<root>/<owner>/<name>.xml` + `.json` manifest.

- [ ] **Step 1: Write the failing test** `src/sink.test.ts`:

```ts
import { test, expect } from "bun:test";
import { StagingSink } from "./sink";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

test("StagingSink writes pack + manifest", async () => {
  const root = mkdtempSync(join(tmpdir(), "brain-"));
  const sink = new StagingSink(root);
  await sink.write(new TextEncoder().encode("PACK"), {
    slug: "acme/widget", owner: "acme", name: "widget",
    commit: "deadbeef", hash: "abc123", bytes: 4, ts: "2026-07-12T00:00:00Z",
  });
  expect(existsSync(join(root, "acme/widget.xml"))).toBe(true);
  const manifest = JSON.parse(readFileSync(join(root, "acme/widget.json"), "utf8"));
  expect(manifest.slug).toBe("acme/widget");
  expect(manifest.hash).toBe("abc123");
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/sink.test.ts`
Expected: FAIL — `StagingSink` not found.

- [ ] **Step 3: Implement `src/sink.ts`:**

```ts
import { mkdirSync } from "node:fs";
import { join, dirname } from "node:path";

export interface RepoMeta {
  slug: string; owner: string; name: string;
  commit: string; hash: string; bytes: number; ts: string;
}

export interface PackSink {
  write(packBytes: Uint8Array, meta: RepoMeta): Promise<void>;
}

export class StagingSink implements PackSink {
  constructor(private root: string) {}
  async write(packBytes: Uint8Array, meta: RepoMeta): Promise<void> {
    const xml = join(this.root, `${meta.owner}/${meta.name}.xml`);
    const json = join(this.root, `${meta.owner}/${meta.name}.json`);
    mkdirSync(dirname(xml), { recursive: true });
    await Bun.write(xml, packBytes);
    await Bun.write(json, JSON.stringify(meta, null, 2));
  }
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/sink.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add scripts/repomix-pack/src/sink.ts scripts/repomix-pack/src/sink.test.ts
git commit -m "feat(repomix): brain sink seam + StagingSink (#<ticket>)"
```

---

## Task 8: Slack notify

**Files:**
- Create: `scripts/repomix-pack/src/notify.ts`
- Test: `scripts/repomix-pack/src/notify.test.ts`

**Interfaces:**
- Produces:
  - `buildSlackPayload(p: { slug: string; base: string; prUrl: string; created: boolean; bytes: number }): object` (pure, testable).
  - `notifySlack(webhook: string, payload: object): Promise<void>` (posts; skipped when `webhook` is empty).
  - `resolveWebhook(): Promise<string>` — reads `SLACK_WEBHOOK` env, else `op read op://Dev/repomix-pipeline/slack_webhook`, else `""`.

- [ ] **Step 1: Write the failing test** `src/notify.test.ts`:

```ts
import { test, expect } from "bun:test";
import { buildSlackPayload } from "./notify";

test("payload includes repo, action verb, and PR link", () => {
  const p = buildSlackPayload({
    slug: "nwlnexus/olympus-sdk", base: "main",
    prUrl: "https://github.com/nwlnexus/olympus-sdk/pull/9",
    created: true, bytes: 12345,
  });
  const text = JSON.stringify(p);
  expect(text).toContain("nwlnexus/olympus-sdk");
  expect(text).toContain("opened");
  expect(text).toContain("/pull/9");
});

test("updated PR uses 'updated' verb", () => {
  const p = buildSlackPayload({
    slug: "a/b", base: "main", prUrl: "u", created: false, bytes: 1,
  });
  expect(JSON.stringify(p)).toContain("updated");
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/notify.test.ts`
Expected: FAIL — `buildSlackPayload` not found.

- [ ] **Step 3: Implement `src/notify.ts`:**

```ts
import { $ } from "bun";

export function buildSlackPayload(p: {
  slug: string; base: string; prUrl: string; created: boolean; bytes: number;
}): object {
  const verb = p.created ? "opened" : "updated";
  return {
    text: `repomix pack ${verb} for *${p.slug}* → <${p.prUrl}|review PR> (${p.bytes} bytes on ${p.base})`,
  };
}

export async function resolveWebhook(): Promise<string> {
  if (process.env.SLACK_WEBHOOK) return process.env.SLACK_WEBHOOK;
  const op = await $`op read op://Dev/repomix-pipeline/slack_webhook`.text().catch(() => "");
  return op.trim();
}

export async function notifySlack(webhook: string, payload: object): Promise<void> {
  if (!webhook) return;
  await fetch(webhook, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/notify.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit.**

```bash
git add scripts/repomix-pack/src/notify.ts scripts/repomix-pack/src/notify.test.ts
git commit -m "feat(repomix): slack notification payload + sender (#<ticket>)"
```

---

## Task 9: Runner orchestration + CLI

**Files:**
- Create: `scripts/repomix-pack/src/index.ts`
- Test: `scripts/repomix-pack/src/index.test.ts` (integration; requires real `repomix` on PATH — Task 1)

**Interfaces:**
- Consumes: all of Tasks 2–8.
- Produces: CLI `repomix-pack [--group g] [--only slug…] [--dry-run] [--no-pr] [--brain-only] [--no-notify]`, and `run(opts): Promise<RunSummary>` where `RunSummary = { succeeded: string[]; skipped: string[]; failed: {slug:string;error:string}[]; prs: {slug:string;url:string}[] }`.

- [ ] **Step 1: Write the failing integration test** `src/index.test.ts` (drives one repo end-to-end against a bare origin, `--no-pr --no-notify`, asserting the pack is produced and staged):

```ts
import { test, expect } from "bun:test";
import { run } from "./index";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("run packs a repo and stages to brain (no PR)", async () => {
  // Fake origin with real content so repomix has something to pack.
  const root = mkdtempSync(join(tmpdir(), "run-"));
  const work = join(root, "work");
  mkdirSync(work);
  await $`git -C ${work} init -q -b main`;
  writeFileSync(join(work, "app.ts"), "export const x = 1;\n");
  await $`git -C ${work} add -A`;
  await $`git -C ${work} -c user.email=t@t -c user.name=t commit -qm init`;
  const bare = join(root, "origin.git");
  await $`git clone -q --bare ${work} ${bare}`;

  const toml = join(root, "repos.toml");
  writeFileSync(toml, `
[defaults]
pack_path = ".llm/repomix.xml"
branch = "automation/repomix-pack"
[groups.personal]
ssh_host = "github.com"
owner = "acme"
repos = ["widget"]
`);
  // Point the single target's originUrl at our bare repo via env override.
  const cacheRoot = join(root, "cache");
  const brainRoot = join(root, "brain");
  const summary = await run({
    tomlPath: toml,
    configPath: join(process.cwd(), "..", "..", "modules/repomix/repomix.config.json"),
    cacheRoot, brainRoot, noPr: true, noNotify: true,
    originOverride: { "acme/widget": bare },
  });
  expect(summary.succeeded).toContain("acme/widget");
  expect(existsSync(join(brainRoot, "acme/widget.xml"))).toBe(true);
});
```

- [ ] **Step 2: Run test, verify it fails.**

Run: `cd scripts/repomix-pack && bun test src/index.test.ts`
Expected: FAIL — `run` not found.

- [ ] **Step 3: Implement `src/index.ts`:**

```ts
import { loadTargets } from "./config";
import { checkout } from "./checkout";
import { runPack, packChanged } from "./pack";
import { ensureTracked } from "./gitignore";
import { commitToBranch, openOrUpdatePr } from "./git-pr";
import { StagingSink, RepoMeta } from "./sink";
import { buildSlackPayload, resolveWebhook, notifySlack } from "./notify";
import { join } from "node:path";

export interface RunSummary {
  succeeded: string[];
  skipped: string[];
  failed: { slug: string; error: string }[];
  prs: { slug: string; url: string }[];
}

export interface RunOpts {
  tomlPath: string;
  configPath: string;
  cacheRoot: string;
  brainRoot: string;
  group?: string;
  only?: string[];
  dryRun?: boolean;
  noPr?: boolean;
  brainOnly?: boolean;
  noNotify?: boolean;
  originOverride?: Record<string, string>; // test seam
  concurrency?: number;
}

export async function run(opts: RunOpts): Promise<RunSummary> {
  const targets = loadTargets(opts.tomlPath, { group: opts.group, only: opts.only });
  const sink = new StagingSink(opts.brainRoot);
  const webhook = opts.noNotify ? "" : await resolveWebhook();
  const summary: RunSummary = { succeeded: [], skipped: [], failed: [], prs: [] };
  const limit = opts.concurrency ?? 4;

  const queue = [...targets];
  async function worker() {
    for (let t = queue.shift(); t; t = queue.shift()) {
      try {
        if (opts.originOverride?.[t.slug]) t.originUrl = opts.originOverride[t.slug];
        const { dir, defaultBranch, headSha } = await checkout(t, opts.cacheRoot);
        await runPack(dir, opts.configPath);
        const gate = await packChanged(dir, t.packPath);
        if (!gate.changed) { summary.skipped.push(t.slug); continue; }

        const packBytes = new Uint8Array(
          await Bun.file(join(dir, t.packPath)).arrayBuffer(),
        );
        const meta: RepoMeta = {
          slug: t.slug, owner: t.owner, name: t.name, commit: headSha,
          hash: gate.newHash, bytes: gate.bytes, ts: new Date().toISOString(),
        };
        await sink.write(packBytes, meta);

        if (!opts.brainOnly && !opts.dryRun) {
          await ensureTracked(dir, t.packPath);
          await commitToBranch(dir, t, defaultBranch, [t.packPath, ".gitignore"]);
          if (!opts.noPr) {
            const pr = await openOrUpdatePr(
              t, defaultBranch, "chore: refresh repomix context pack",
              `Automated repomix context pack refresh.\n\nCloses the paired tracking sub-issue.\nPack: \`${t.packPath}\` (${gate.bytes} bytes).`,
            );
            summary.prs.push({ slug: t.slug, url: pr.url });
            await notifySlack(webhook, buildSlackPayload({
              slug: t.slug, base: defaultBranch, prUrl: pr.url,
              created: pr.created, bytes: gate.bytes,
            }));
          }
        }
        summary.succeeded.push(t.slug);
      } catch (e) {
        summary.failed.push({ slug: t.slug, error: String(e) });
      }
    }
  }
  await Promise.all(Array.from({ length: limit }, worker));
  return summary;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const has = (f: string) => args.includes(f);
  const val = (f: string) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
  const home = process.env.HOME!;
  const summary = await run({
    tomlPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repos.toml`,
    configPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repomix.config.json`,
    cacheRoot: `${home}/.cache/repomix-pipeline`,
    brainRoot: `${home}/.cache/repomix-pipeline/brain-staging`,
    group: val("--group"),
    only: has("--only") ? args.slice(args.indexOf("--only") + 1).filter((a) => a.includes("/")) : undefined,
    dryRun: has("--dry-run"), noPr: has("--no-pr"),
    brainOnly: has("--brain-only"), noNotify: has("--no-notify"),
  });
  console.log(JSON.stringify(summary, null, 2));
  if (summary.failed.length) process.exit(1);
}
```

- [ ] **Step 4: Run test, verify it passes.**

Run: `cd scripts/repomix-pack && bun test src/index.test.ts`
Expected: PASS (requires `repomix` on PATH from Task 1).

- [ ] **Step 5: Run the full suite.**

Run: `cd scripts/repomix-pack && bun test`
Expected: all tests PASS.

- [ ] **Step 6: Commit.**

```bash
git add scripts/repomix-pack/src/index.ts scripts/repomix-pack/src/index.test.ts
git commit -m "feat(repomix): runner orchestration + CLI (#<ticket>)"
```

---

## Task 10: Reusable CI workflow

**Files:**
- Create: `.github/workflows/repomix-pack.yml`

**Interfaces:**
- Produces: a `workflow_call` workflow referenced by caller repos as `nwlnexus/nix-darwin-hm/.github/workflows/repomix-pack.yml@main`.

- [ ] **Step 1: Create `.github/workflows/repomix-pack.yml`:**

```yaml
name: repomix-pack
on:
  workflow_call:
    inputs:
      pack_path:
        type: string
        default: ".llm/repomix.xml"
    secrets:
      SLACK_WEBHOOK:
        required: false
concurrency:
  group: repomix-pack-${{ github.repository }}
  cancel-in-progress: true
permissions:
  contents: write
  pull-requests: write
jobs:
  pack:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "24" }
      - name: Generate pack
        run: |
          npx --yes repomix --style xml --output "${{ inputs.pack_path }}" \
            --ignore ".llm/**" .
      - name: Guarantee tracked
        run: |
          if git check-ignore "${{ inputs.pack_path }}" >/dev/null 2>&1; then
            printf '\n# repomix pipeline: keep context pack tracked\n!/%s/\n' \
              "$(dirname "${{ inputs.pack_path }}")" >> .gitignore
          fi
      - name: Create or update PR
        uses: peter-evans/create-pull-request@v6
        id: cpr
        with:
          branch: automation/repomix-pack
          base: ${{ github.event.repository.default_branch }}
          add-paths: |
            ${{ inputs.pack_path }}
            .gitignore
          commit-message: "chore: refresh repomix context pack"
          title: "chore: refresh repomix context pack"
          body: "Automated repomix context pack refresh."
          labels: automation
      - name: Slack notify
        if: steps.cpr.outputs.pull-request-operation != ''
        env:
          WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
          URL: ${{ steps.cpr.outputs.pull-request-url }}
          OP: ${{ steps.cpr.outputs.pull-request-operation }}
        run: |
          [ -z "$WEBHOOK" ] && exit 0
          curl -sf -X POST -H 'content-type: application/json' \
            --data "{\"text\":\"repomix pack $OP for *${{ github.repository }}* → <$URL|review PR>\"}" \
            "$WEBHOOK"
```

- [ ] **Step 2: Validate workflow syntax.**

Run: `gh workflow view repomix-pack --repo nwlnexus/nix-darwin-hm 2>&1 | head -3` (after commit+push) or lint locally with `actionlint .github/workflows/repomix-pack.yml`
Expected: no syntax errors.

- [ ] **Step 3: Enable private reusable-workflow access (one-time, manual).**

In GitHub: `nix-darwin-hm` → Settings → Actions → General → "Access" → allow "Accessible from repositories owned by nwilliams-lucas". Note this step's completion in the sub-issue.

- [ ] **Step 4: Commit.**

```bash
git add .github/workflows/repomix-pack.yml
git commit -m "feat(repomix): reusable CI workflow for per-repo packs (#<ticket>)"
```

---

## Task 11: Pilot caller on olympus-sdk

**Files:**
- Create (in the **olympus-sdk** repo, separate checkout): `.github/workflows/pack.yml`

**Interfaces:**
- Consumes: the reusable workflow (Task 10).

- [ ] **Step 1: In an isolated checkout of `nwlnexus/olympus-sdk`, create `.github/workflows/pack.yml`:**

```yaml
name: pack
on:
  push:
    branches: [main]
    paths-ignore: [".llm/**"]
  workflow_dispatch:
jobs:
  pack:
    uses: nwlnexus/nix-darwin-hm/.github/workflows/repomix-pack.yml@main
    secrets: inherit
```

- [ ] **Step 2: Open the caller via a normal PR** (respects branch protection):

```bash
git checkout -b ci/repomix-pack
git add .github/workflows/pack.yml
git commit -m "ci: generate repomix context pack on push (#<ticket>)"
git push -u origin ci/repomix-pack
gh pr create --fill --label automation
```

- [ ] **Step 3: After merge, trigger and verify.**

Run: `gh workflow run pack.yml --repo nwlnexus/olympus-sdk && sleep 30 && gh run list --repo nwlnexus/olympus-sdk --workflow pack.yml --limit 1`
Expected: run succeeds; an `automation/repomix-pack` PR appears with `.llm/repomix.xml`; Slack posts (if webhook secret set).

- [ ] **Step 4: Verify self-trigger guard.** Confirm merging the pack PR does **not** start a new `pack` run (because of `paths-ignore: .llm/**`). Record the observation in the sub-issue.

---

## Task 12: Nix PATH install + launchd

**Files:**
- Create: `modules/repomix/repomix.nix`
- Modify: the host/profile module that imports `modules/repomix/` (follow the existing import pattern in `modules/profiles/dev.nix`)

**Interfaces:**
- Consumes: the runner (Task 9).
- Produces: `repomix-pack` on `PATH`; a launchd agent running it on a schedule.

- [ ] **Step 1: Create `modules/repomix/repomix.nix`:**

```nix
{ config, pkgs, lib, ... }:
let
  repoRoot = "${config.home.homeDirectory}/projects/personal/nix-darwin-hm";
  repomix-pack = pkgs.writeShellApplication {
    name = "repomix-pack";
    runtimeInputs = [ pkgs.bun pkgs.git pkgs.gh pkgs._1password-cli ];
    text = ''exec bun run "${repoRoot}/scripts/repomix-pack/src/index.ts" "$@"'';
  };
in {
  home.packages = [ repomix-pack ];

  launchd.agents.repomix-pack = {
    enable = true;
    config = {
      ProgramArguments = [ "${repomix-pack}/bin/repomix-pack" "--group" "all" ];
      StartCalendarInterval = [ { Hour = 9; Minute = 0; } ];
      RunAtLoad = false;
      StandardOutPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.err.log";
    };
  };
}
```

> Note: `--group all` means "no group filter"; `loadTargets` treats an absent/`all` group as unfiltered — confirm `index.ts` maps `--group all` to `undefined` (add that one-line guard if missing).

- [ ] **Step 2: Import the module** where profiles are wired (mirror how `modules/profiles/dev.nix` imports siblings). Add `../repomix/repomix.nix` to the relevant `imports = [ ... ]`.

- [ ] **Step 3: Build and verify.**

Run: `darwin-rebuild build --flake ~/projects/personal/nix-darwin-hm#$(hostname -s) 2>&1 | tail -5`
Expected: builds clean; `repomix-pack` resolves after switch.

- [ ] **Step 4: Commit.**

```bash
git add modules/repomix/repomix.nix modules/profiles/dev.nix
git commit -m "feat(repomix): PATH install + launchd schedule (#<ticket>)"
```

---

## Task 13: Fan-out callers + work sweep

**Files:**
- Create (per personal repo): `.github/workflows/pack.yml` (identical to Task 11, adjusting default branch if not `main`)

**Interfaces:**
- Consumes: Tasks 11 (proven pilot) and 12 (local runner installed).

- [ ] **Step 1: Add the caller workflow (Task 11 Step 1 content) via PR to each remaining personal repo:** `olympus-gitops`, `olympus-infra`, `nix-darwin-hm`, `moneta`, `nix-op-secrets`, `second-brain`, `olympus-tailnet`, `homebrew-olympus`. Each PR: `ci: generate repomix context pack on push`, label `automation`, referencing this task's sub-issue.

- [ ] **Step 2: Seed the work group locally** (dtlr repos excluded from CI per org policy):

Run: `repomix-pack --group work`
Expected: `marquee` and `drop-app` get `automation/repomix-pack` PRs (via your work `gh`/SSH auth); Slack posts.

- [ ] **Step 3: Full fleet dry-run sanity.**

Run: `repomix-pack --group all --dry-run`
Expected: summary lists every repo as succeeded/skipped with zero failures; no PRs opened.

- [ ] **Step 4: Close-out.** Update the epic: confirm all sub-issues closed, check the plan's Ticket Map, and note Project 2 (brain) as the follow-on.

---

## Self-Review Notes

- **Spec coverage:** config (T1/T2), isolated checkout (T3), pack+gate (T4), tracked-guarantee (T5), branch/PR (T6), brain seam (T7), Slack (T8), orchestration/CLI/isolation/summary (T9), reusable CI + self-trigger guard (T10/T11), nix globals+PATH+launchd (T1/T12), gitnexus install durability (T1), rollout order (T1→T13). Project-2 items are explicitly out of scope.
- **Placeholder scan:** `#<ticket>` markers are intentional and are replaced with real sub-issue numbers from the Ticket Map during execution; no `TBD`/`TODO` logic remains.
- **Type consistency:** `RepoTarget`, `RepoMeta`, `PackSink`/`StagingSink`, `RunSummary`, `loadTargets`, `checkout`, `runPack`/`packChanged`, `ensureTracked`, `commitToBranch`/`openOrUpdatePr`, `buildSlackPayload`/`resolveWebhook`/`notifySlack`, `run` are consistent across tasks.
