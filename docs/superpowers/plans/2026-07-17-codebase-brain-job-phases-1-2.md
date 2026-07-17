# Codebase Brain Job (Phases 1–2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the on-prem Job application that, for one allowlisted repo at a pinned sha, runs pack + gitnexus + syft (+ facets), publishes graph refs/tarball to R2 (phase 1), then runs openwiki (Anthropic) + syft inventory + OKF/nwl normalize + brain PR (phase 2).

**Architecture:** New Bun/TS app under `scripts/codebase-brain/` reuses `scripts/repomix-pack` pack/graph helpers and `modules/repomix/{repos.toml,repomix.config.json}`. Stages are pure-ish modules with digests; a thin CLI orchestrates them. Argo Events/Workflows and ExternalSecrets live in **olympus-gitops** (out of this repo) and invoke the Job image. Moneta capture and shared GitNexus MCP serve are **out of scope** (phases 3–4).

**Tech Stack:** Bun/TypeScript, Zod, repomix, gitnexus, openwiki@0.2.x, syft, AWS S3 API (R2), `gh`/`git`, Anthropic API (openwiki native provider).

**Spec:** [`docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md`](../specs/2026-07-15-codebase-brain-pipeline-design.md)  
**Spike evidence:** [`docs/superpowers/specs/2026-07-17-codebase-brain-openwiki-spike-results.md`](../specs/2026-07-17-codebase-brain-openwiki-spike-results.md)

## Global Constraints

- Runner language: **Bun/TypeScript**. Tests: `bun test`.
- Job ships CLIs on PATH: **`repomix`**, **`gitnexus`**, **`openwiki`**, **`syft`** — all callable.
- Layer 1 narrative: **openwiki code mode + Anthropic only** (not Studio Ollama).
- Inventory: **syft only** — never LLM-authored dependency rows.
- OpenWiki **personal** mode forbidden.
- Strip openwiki side effects before brain publish: `AGENTS.md`, `CLAUDE.md`, `.github/workflows/openwiki-*.yml` mutations must not land in the brain PR.
- Serialize per repo (no concurrent openwiki on one tree). Mutex name: `brain-{owner}-{repo}`.
- Skip LLM when `(packHash, graphDigest, sbomDigest, templateVersion)` unchanged vs last success marker.
- Publish order: **R2 graph → (Moneta later) → brain PR**. Validate fail ⇒ no R2 `latest`, no brain push.
- Graph consumer contract **C**: Moneta stores refs only; shared MCP is canonical (not built here).
- Allowlist source of truth: `modules/repomix/repos.toml` (personal/`nwlnexus` first; no `dtlr` in v1 Job allowlist).
- Provisional central brain repo: **`second-brain`**, content path `docs/codebases/{repo}/` (override via env if renamed).
- Template version string: `openwiki-0.2`.
- Secrets: Anthropic + GitHub App + R2 via env / ExternalSecrets (never commit). Spike used `op://Dev/docs-api-key` for Anthropic locally.

**Out of this plan:** Moneta `/capture`, shared GitNexus Container MCP, launchd cutover, mnemosyne convenience, Workers facets.

---

## File Structure

```text
scripts/codebase-brain/
  package.json
  tsconfig.json
  Containerfile                 # Job image (repomix, gitnexus, openwiki, syft, bun)
  src/
    index.ts                    # CLI: --owner --repo --sha --phase 1|2|all
    types.ts                    # JobContext, digests, GraphRef
    digests.ts                  # sha256 helpers + skip gate
    stages/
      clone.ts                  # shallow clone at sha into workdir
      pack.ts                   # wrap runPack + packHash
      analyze.ts                # gitnexus analyze + graphDigest + tarball path
      sbom.ts                   # syft → sbom.cdx.json + sbomDigest
      facets.ts                 # thin facet.json from graph hints (best-effort)
      openwiki.ts               # openwiki code --update -p; copy wiki out
      inventory.ts              # renderInventory from CycloneDX
      normalize.ts              # stamp nwl extensions + Zod validate
      strip-side-effects.ts     # filter publish set
    publish/
      r2-graph.ts               # upload tarball + graph-ref + latest marker
      brain-pr.ts               # push docs to second-brain automation/brain-{repo}
    schema/
      frontmatter.ts            # Zod OKF base + nwl extensions
  tests/                        # colocated *.test.ts next to modules is fine
modules/repomix/repos.toml      # SoT allowlist (read-only for Job)
modules/repomix/repomix.config.json
docs/superpowers/plans/…        # this plan
# olympus-gitops (EXTERNAL): Argo EventSource/Sensor/WorkflowTemplate + ExternalSecrets
```

---

### Task 1: Scaffold `scripts/codebase-brain`

**Files:**
- Create: `scripts/codebase-brain/package.json`
- Create: `scripts/codebase-brain/tsconfig.json`
- Create: `scripts/codebase-brain/src/types.ts`
- Create: `scripts/codebase-brain/src/index.ts` (stub CLI)

**Interfaces:**
- Produces: `JobContext`, `Digests`, `GraphRef` types used by all later stages

- [ ] **Step 1: Create package.json and tsconfig**

```json
{
  "name": "codebase-brain",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "bun run src/index.ts",
    "test": "bun test"
  },
  "dependencies": {
    "zod": "^3.24.0",
    "yaml": "^2.7.0"
  },
  "devDependencies": {
    "@types/bun": "latest"
  }
}
```

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "types": ["bun-types"],
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 2: Write types**

```typescript
// scripts/codebase-brain/src/types.ts
export type Phase = 1 | 2 | "all";

export interface Digests {
  packHash: string;
  graphDigest: string;
  sbomDigest: string;
  templateVersion: string;
}

export interface GraphRef {
  owner: string;
  repo: string;
  sha: string;
  graphDigest: string;
  r2Uri: string;
  latestUri: string;
  intent: "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later";
}

export interface JobContext {
  owner: string;
  repo: string;
  sha: string;
  workDir: string;
  outDir: string;
  packPath: string;
  configPath: string;
  brainRepo: string;
  brainContentRoot: string;
  r2Bucket: string;
  r2Prefix: string;
  anthropicApiKey?: string;
  dryRun: boolean;
  phase: Phase;
}
```

- [ ] **Step 3: Stub CLI that parses flags and prints JSON context**

```typescript
// scripts/codebase-brain/src/index.ts
import { parseArgs } from "node:util";
import type { JobContext, Phase } from "./types";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";

export function buildContext(argv: string[]): JobContext {
  const { values } = parseArgs({
    args: argv,
    options: {
      owner: { type: "string", default: "nwlnexus" },
      repo: { type: "string" },
      sha: { type: "string" },
      phase: { type: "string", default: "all" },
      "work-root": { type: "string", default: "/tmp/codebase-brain-job" },
      "dry-run": { type: "boolean", default: false },
      "brain-repo": { type: "string", default: "second-brain" },
      "config-path": {
        type: "string",
        default: new URL("../../../modules/repomix/repomix.config.json", import.meta.url)
          .pathname,
      },
    },
    strict: true,
  });
  if (!values.repo || !values.sha) throw new Error("--repo and --sha are required");
  const phase = values.phase as Phase;
  if (phase !== 1 && phase !== 2 && phase !== "all") {
    throw new Error("--phase must be 1 | 2 | all");
  }
  const workRoot = values["work-root"]!;
  const workDir = join(workRoot, "repos", values.owner!, values.repo);
  const outDir = join(workRoot, "out", values.owner!, values.repo, values.sha);
  return {
    owner: values.owner!,
    repo: values.repo,
    sha: values.sha,
    workDir,
    outDir,
    packPath: ".llm/repomix.xml",
    configPath: values["config-path"]!,
    brainRepo: values["brain-repo"]!,
    brainContentRoot: "docs/codebases",
    r2Bucket: process.env.BRAIN_R2_BUCKET ?? "nwl-codebase-brain",
    r2Prefix: "graphs",
    anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    dryRun: Boolean(values["dry-run"]),
    phase,
  };
}

if (import.meta.main) {
  const ctx = buildContext(process.argv.slice(2));
  await mkdir(ctx.outDir, { recursive: true });
  console.log(JSON.stringify(ctx, null, 2));
}
```

- [ ] **Step 4: Install and smoke the stub**

Run: `cd scripts/codebase-brain && bun install && bun run src/index.ts --repo moneta --sha deadbeef --dry-run`
Expected: JSON with `repo: "moneta"`, `phase: "all"`, paths under `/tmp/codebase-brain-job`.

- [ ] **Step 5: Commit**

```bash
git add scripts/codebase-brain/package.json scripts/codebase-brain/tsconfig.json \
  scripts/codebase-brain/src/types.ts scripts/codebase-brain/src/index.ts \
  scripts/codebase-brain/bun.lock
git commit -m "feat(codebase-brain): scaffold Job CLI and types"
```

---

### Task 2: Digests + skip gate

**Files:**
- Create: `scripts/codebase-brain/src/digests.ts`
- Create: `scripts/codebase-brain/src/digests.test.ts`

**Interfaces:**
- Produces: `sha256Hex(bytes)`, `fileDigest(path)`, `shouldSkipLlm(current, previous)`, `TEMPLATE_VERSION`

- [ ] **Step 1: Write failing tests**

```typescript
// scripts/codebase-brain/src/digests.test.ts
import { describe, expect, test } from "bun:test";
import { sha256Hex, shouldSkipLlm, TEMPLATE_VERSION } from "./digests";

describe("digests", () => {
  test("sha256Hex is stable", () => {
    expect(sha256Hex("abc")).toBe(sha256Hex("abc"));
    expect(sha256Hex("abc")).not.toBe(sha256Hex("abd"));
  });

  test("shouldSkipLlm when all digests match", () => {
    const d = {
      packHash: "a",
      graphDigest: "b",
      sbomDigest: "c",
      templateVersion: TEMPLATE_VERSION,
    };
    expect(shouldSkipLlm(d, d)).toBe(true);
    expect(shouldSkipLlm(d, { ...d, packHash: "x" })).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd scripts/codebase-brain && bun test src/digests.test.ts`
Expected: FAIL module not found / exports missing.

- [ ] **Step 3: Implement**

```typescript
// scripts/codebase-brain/src/digests.ts
import { createHash } from "node:crypto";
import type { Digests } from "./types";

export const TEMPLATE_VERSION = "openwiki-0.2";

export function sha256Hex(input: string | Uint8Array): string {
  const h = createHash("sha256");
  h.update(typeof input === "string" ? Buffer.from(input) : input);
  return `sha256:${h.digest("hex")}`;
}

export async function fileDigest(path: string): Promise<string> {
  const bytes = new Uint8Array(await Bun.file(path).arrayBuffer());
  return sha256Hex(bytes);
}

export function shouldSkipLlm(current: Digests, previous: Digests | null): boolean {
  if (!previous) return false;
  return (
    current.packHash === previous.packHash &&
    current.graphDigest === previous.graphDigest &&
    current.sbomDigest === previous.sbomDigest &&
    current.templateVersion === previous.templateVersion
  );
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `cd scripts/codebase-brain && bun test src/digests.test.ts`

- [ ] **Step 5: Commit**

```bash
git add scripts/codebase-brain/src/digests.ts scripts/codebase-brain/src/digests.test.ts
git commit -m "feat(codebase-brain): add digest helpers and LLM skip gate"
```

---

### Task 3: Syft SBOM stage

**Files:**
- Create: `scripts/codebase-brain/src/stages/sbom.ts`
- Create: `scripts/codebase-brain/src/stages/sbom.test.ts`

**Interfaces:**
- Consumes: `JobContext`
- Produces: `runSbom(ctx) → { sbomPath, sbomDigest }`

- [ ] **Step 1: Write failing test with fixture SBOM write path**

```typescript
import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseSbomDigest } from "./sbom";

describe("sbom", () => {
  test("parseSbomDigest hashes file contents", async () => {
    const dir = await mkdtemp(join(tmpdir(), "sbom-"));
    const p = join(dir, "sbom.cdx.json");
    await writeFile(p, JSON.stringify({ bomFormat: "CycloneDX", components: [] }));
    const d = await parseSbomDigest(p);
    expect(d.startsWith("sha256:")).toBe(true);
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd scripts/codebase-brain && bun test src/stages/sbom.test.ts`

- [ ] **Step 3: Implement stage**

```typescript
// scripts/codebase-brain/src/stages/sbom.ts
import { $ } from "bun";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest } from "../digests";

export async function parseSbomDigest(sbomPath: string): Promise<string> {
  return fileDigest(sbomPath);
}

export async function runSbom(ctx: JobContext): Promise<{ sbomPath: string; sbomDigest: string }> {
  await mkdir(ctx.outDir, { recursive: true });
  const sbomPath = join(ctx.outDir, "sbom.cdx.json");
  const res = await $`syft ${ctx.workDir} -o cyclonedx-json=${sbomPath}`.quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(`syft failed (${res.exitCode}): ${res.stderr.toString()}`);
  }
  return { sbomPath, sbomDigest: await parseSbomDigest(sbomPath) };
}
```

- [ ] **Step 4: Run unit test PASS; optional integration if `syft` on PATH**

Run: `cd scripts/codebase-brain && bun test src/stages/sbom.test.ts`
Optional: `command -v syft && bun -e '…'` against a tiny dir.

- [ ] **Step 5: Commit**

```bash
git add scripts/codebase-brain/src/stages/sbom.ts scripts/codebase-brain/src/stages/sbom.test.ts
git commit -m "feat(codebase-brain): add syft CycloneDX stage"
```

---

### Task 4: Inventory renderer (syft → MD)

**Files:**
- Create: `scripts/codebase-brain/src/stages/inventory.ts`
- Create: `scripts/codebase-brain/src/stages/inventory.test.ts`

**Interfaces:**
- Consumes: CycloneDX JSON
- Produces: `renderInventory(sbom): string`, `writeInventoryPage(ctx, sbomPath, digests, graphRef)`

- [ ] **Step 1: Failing test**

```typescript
import { describe, expect, test } from "bun:test";
import { renderInventory } from "./inventory";

describe("renderInventory", () => {
  test("sorts components and builds table", () => {
    const md = renderInventory({
      components: [
        { name: "zod", version: "3.0.0", type: "library" },
        { name: "bun", version: "1.2.0", type: "library" },
      ],
    });
    expect(md).toContain("| bun | 1.2.0 | library |");
    expect(md).toContain("| zod | 3.0.0 | library |");
    expect(md.indexOf("bun")).toBeLessThan(md.indexOf("zod"));
  });
});
```

- [ ] **Step 2: Run — FAIL**

Run: `cd scripts/codebase-brain && bun test src/stages/inventory.test.ts`

- [ ] **Step 3: Implement (port spike)**

```typescript
// scripts/codebase-brain/src/stages/inventory.ts
import { join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import type { Digests, GraphRef, JobContext } from "../types";

export interface SbomComponent { name: string; version?: string; type?: string }
export interface Sbom { bomFormat?: string; components?: SbomComponent[] }

export function renderInventory(sbom: Sbom): string {
  const comps = (sbom.components ?? [])
    .filter((c) => c.name)
    .sort((a, b) => a.name.localeCompare(b.name));
  const rows = comps
    .map((c) => `| ${c.name} | ${c.version ?? ""} | ${c.type ?? ""} |`)
    .join("\n");
  return [
    `Components: ${comps.length}`,
    "",
    "| Name | Version | Type |",
    "| --- | --- | --- |",
    rows,
    "",
  ].join("\n");
}

export async function writeInventoryPage(
  ctx: JobContext,
  sbomPath: string,
  digests: Digests,
  graph: GraphRef,
): Promise<string> {
  const sbom = (await Bun.file(sbomPath).json()) as Sbom;
  const body = renderInventory(sbom);
  const fm = [
    "---",
    "type: Tech Inventory",
    `title: ${ctx.repo} — Tech Inventory`,
    "description: CycloneDX-derived dependency inventory",
    "tags: [sbom, inventory]",
    "docType: inventory",
    `repo: ${ctx.repo}`,
    `owner: ${ctx.owner}`,
    `slug: ${ctx.repo}/tech-inventory`,
    "source:",
    `  sha: ${ctx.sha}`,
    `  packHash: ${digests.packHash}`,
    `  graphDigest: ${digests.graphDigest}`,
    `  graphUri: ${graph.r2Uri}`,
    `  templateVersion: ${digests.templateVersion}`,
    `brainPath: ${ctx.brainContentRoot}/${ctx.repo}/tech-inventory.md`,
    "status: generated",
    "---",
    "",
    body,
  ].join("\n");
  const docsDir = join(ctx.outDir, "brain-docs", ctx.repo);
  await mkdir(docsDir, { recursive: true });
  const out = join(docsDir, "tech-inventory.md");
  await writeFile(out, fm);
  return out;
}
```

- [ ] **Step 4: PASS + commit**

```bash
cd scripts/codebase-brain && bun test src/stages/inventory.test.ts
git add scripts/codebase-brain/src/stages/inventory.ts scripts/codebase-brain/src/stages/inventory.test.ts
git commit -m "feat(codebase-brain): deterministic syft inventory page"
```

---

### Task 5: Frontmatter Zod + normalize OKF pages

**Files:**
- Create: `scripts/codebase-brain/src/schema/frontmatter.ts`
- Create: `scripts/codebase-brain/src/schema/frontmatter.test.ts`
- Create: `scripts/codebase-brain/src/stages/normalize.ts`
- Create: `scripts/codebase-brain/src/stages/normalize.test.ts`

**Interfaces:**
- Produces: `NwlFrontmatterSchema`, `stampNwlExtensions(rawMd, ctx, digests, graph) → string`, `normalizeWikiDir(...)`

- [ ] **Step 1: Failing schema test**

```typescript
import { describe, expect, test } from "bun:test";
import { NwlDocSchema } from "./frontmatter";

describe("NwlDocSchema", () => {
  test("requires nwl extensions", () => {
    const ok = NwlDocSchema.safeParse({
      type: "Repository Overview",
      title: "moneta",
      description: "x",
      tags: ["a"],
      docType: "overview",
      repo: "moneta",
      owner: "nwlnexus",
      slug: "moneta/overview",
      source: {
        sha: "abc",
        packHash: "sha256:1",
        graphDigest: "sha256:2",
        graphUri: "r2://graphs/nwlnexus/moneta/abc",
        templateVersion: "openwiki-0.2",
      },
      brainPath: "docs/codebases/moneta/overview.md",
      status: "generated",
    });
    expect(ok.success).toBe(true);
  });
});
```

- [ ] **Step 2: Implement schema + stamp**

```typescript
// scripts/codebase-brain/src/schema/frontmatter.ts
import { z } from "zod";

export const NwlDocSchema = z.object({
  type: z.string().optional(),
  title: z.string(),
  description: z.string().optional(),
  tags: z.array(z.string()).optional(),
  resource: z.unknown().optional(),
  timestamp: z.string().optional(),
  docType: z.enum(["overview", "inventory", "cluster"]).or(z.string()),
  repo: z.string(),
  owner: z.string(),
  slug: z.string(),
  source: z.object({
    sha: z.string(),
    packHash: z.string(),
    graphDigest: z.string(),
    graphUri: z.string(),
    templateVersion: z.string(),
  }),
  brainPath: z.string(),
  status: z.literal("generated"),
});

export type NwlDoc = z.infer<typeof NwlDocSchema>;
```

```typescript
// scripts/codebase-brain/src/stages/normalize.ts
import YAML from "yaml";
import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { NwlDocSchema } from "../schema/frontmatter";
import type { Digests, GraphRef, JobContext } from "../types";

const FM_RE = /^---\n([\s\S]*?)\n---\n?/;

export function splitFrontmatter(md: string): { fm: Record<string, unknown>; body: string } {
  const m = md.match(FM_RE);
  if (!m) return { fm: {}, body: md };
  return { fm: (YAML.parse(m[1]) as Record<string, unknown>) ?? {}, body: md.slice(m[0].length) };
}

export function guessDocType(name: string, fm: Record<string, unknown>): string {
  if (typeof fm.docType === "string") return fm.docType;
  const n = name.toLowerCase();
  if (n.includes("inventory")) return "inventory";
  if (n.includes("cluster")) return "cluster";
  return "overview";
}

export function stampNwlExtensions(
  md: string,
  fileName: string,
  ctx: JobContext,
  digests: Digests,
  graph: GraphRef,
): string {
  const { fm, body } = splitFrontmatter(md);
  const slugBase = basename(fileName, ".md").toLowerCase().replace(/\s+/g, "-");
  const docType = guessDocType(fileName, fm);
  const stamped = {
    ...fm,
    title: String(fm.title ?? `${ctx.repo} — ${slugBase}`),
    docType,
    repo: ctx.repo,
    owner: ctx.owner,
    slug: `${ctx.repo}/${slugBase}`,
    source: {
      sha: ctx.sha,
      packHash: digests.packHash,
      graphDigest: digests.graphDigest,
      graphUri: graph.r2Uri,
      templateVersion: digests.templateVersion,
    },
    brainPath: `${ctx.brainContentRoot}/${ctx.repo}/${slugBase}.md`,
    status: "generated" as const,
  };
  NwlDocSchema.parse(stamped);
  return `---\n${YAML.stringify(stamped).trim()}\n---\n\n${body.trimStart()}`;
}

export async function normalizeWikiDir(
  wikiDir: string,
  ctx: JobContext,
  digests: Digests,
  graph: GraphRef,
): Promise<string[]> {
  const outDir = join(ctx.outDir, "brain-docs", ctx.repo);
  await mkdir(outDir, { recursive: true });
  const written: string[] = [];
  const entries = await readdir(wikiDir, { recursive: true });
  for (const rel of entries) {
    if (typeof rel !== "string" || !rel.endsWith(".md")) continue;
    if (rel.includes("_plan") || rel.startsWith("_")) continue;
    const raw = await readFile(join(wikiDir, rel), "utf8");
    const stamped = stampNwlExtensions(raw, rel, ctx, digests, graph);
    const destName = basename(rel);
    const dest = join(outDir, destName);
    await writeFile(dest, stamped);
    written.push(dest);
  }
  return written;
}
```

- [ ] **Step 3: Tests for stamp + schema; run PASS**

```typescript
// normalize.test.ts — assert stamped doc parses and contains graphUri
```

- [ ] **Step 4: Commit**

```bash
git add scripts/codebase-brain/src/schema scripts/codebase-brain/src/stages/normalize.ts \
  scripts/codebase-brain/src/stages/normalize.test.ts \
  scripts/codebase-brain/src/schema/frontmatter.test.ts
git commit -m "feat(codebase-brain): Zod OKF+nwl normalize for wiki pages"
```

---

### Task 6: Strip openwiki side effects

**Files:**
- Create: `scripts/codebase-brain/src/stages/strip-side-effects.ts`
- Create: `scripts/codebase-brain/src/stages/strip-side-effects.test.ts`

**Interfaces:**
- Produces: `isPublishableWikiRel(rel): boolean`, `SIDE_EFFECT_PATTERNS`

- [ ] **Step 1–4: TDD**

```typescript
export const SIDE_EFFECT_PATTERNS = [
  /^AGENTS\.md$/i,
  /^CLAUDE\.md$/i,
  /^\.github\/workflows\/openwiki-.*\.yml$/i,
];

export function isPublishableWikiRel(rel: string): boolean {
  const norm = rel.replace(/\\/g, "/");
  if (SIDE_EFFECT_PATTERNS.some((re) => re.test(norm))) return false;
  if (!norm.endsWith(".md")) return false;
  if (norm.includes("/.git/")) return false;
  return true;
}
```

Tests: reject `AGENTS.md`, `.github/workflows/openwiki-update.yml`; accept `Architecture.md`.

```bash
git commit -m "feat(codebase-brain): filter openwiki side-effect files from publish set"
```

---

### Task 7: Clone + pack + analyze stages

**Files:**
- Create: `scripts/codebase-brain/src/stages/clone.ts`
- Create: `scripts/codebase-brain/src/stages/pack.ts`
- Create: `scripts/codebase-brain/src/stages/analyze.ts`
- Create: `scripts/codebase-brain/src/stages/facets.ts`

**Interfaces:**
- Reuse: `runPack` from `scripts/repomix-pack/src/pack.ts` via relative import or duplicated thin wrapper calling `repomix` CLI (prefer CLI in Job image for isolation).
- Produces: `cloneAtSha`, `runPackStage`, `runAnalyzeStage` → `{ graphDir, graphDigest, tarballPath }`, `runFacetsStage`

- [ ] **Step 1: Implement clone**

```typescript
// scripts/codebase-brain/src/stages/clone.ts
import { $ } from "bun";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";

export async function cloneAtSha(ctx: JobContext): Promise<void> {
  await mkdir(ctx.workDir, { recursive: true });
  const url = `https://github.com/${ctx.owner}/${ctx.repo}.git`;
  // Prefer existing workDir; reset to sha. Token via GH_TOKEN / GIT_ASKPASS in Job.
  const exists = await Bun.file(`${ctx.workDir}/.git/HEAD`).exists();
  if (!exists) {
    const r = await $`git clone --filter=blob:none ${url} ${ctx.workDir}`.nothrow();
    if (r.exitCode !== 0) throw new Error(`clone failed: ${r.stderr.toString()}`);
  }
  const f = await $`git -C ${ctx.workDir} fetch --depth=1 origin ${ctx.sha}`.nothrow();
  if (f.exitCode !== 0) {
    // fall back to full fetch for old shas
    await $`git -C ${ctx.workDir} fetch origin`;
  }
  const c = await $`git -C ${ctx.workDir} checkout --force ${ctx.sha}`.nothrow();
  if (c.exitCode !== 0) throw new Error(`checkout ${ctx.sha} failed: ${c.stderr.toString()}`);
}
```

- [ ] **Step 2: Pack stage (CLI)**

```typescript
import { $ } from "bun";
import { join } from "node:path";
import { copyFile, mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest } from "../digests";

export async function runPackStage(ctx: JobContext): Promise<{ packOut: string; packHash: string }> {
  const res = await $`repomix --config ${ctx.configPath} .`.cwd(ctx.workDir).quiet().nothrow();
  if (res.exitCode !== 0) throw new Error(`repomix failed: ${res.stderr.toString()}`);
  const src = join(ctx.workDir, ctx.packPath);
  await mkdir(ctx.outDir, { recursive: true });
  const packOut = join(ctx.outDir, "repomix.xml");
  await copyFile(src, packOut);
  return { packOut, packHash: await fileDigest(packOut) };
}
```

- [ ] **Step 3: Analyze + graph tarball**

```typescript
import { $ } from "bun";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest, sha256Hex } from "../digests";

export async function runAnalyzeStage(ctx: JobContext): Promise<{
  graphDir: string;
  graphDigest: string;
  tarballPath: string;
}> {
  const res = await $`gitnexus analyze`.cwd(ctx.workDir).quiet().nothrow();
  if (res.exitCode !== 0) throw new Error(`gitnexus analyze failed: ${res.stderr.toString()}`);
  const graphDir = join(ctx.workDir, ".gitnexus");
  await mkdir(ctx.outDir, { recursive: true });
  const tarballPath = join(ctx.outDir, `graph-${ctx.sha}.tgz`);
  const tar = await $`tar -czf ${tarballPath} -C ${ctx.workDir} .gitnexus`.nothrow();
  if (tar.exitCode !== 0) throw new Error(`tar graph failed: ${tar.stderr.toString()}`);
  // Digest the tarball bytes for a stable graphDigest
  const graphDigest = await fileDigest(tarballPath);
  return { graphDir, graphDigest, tarballPath };
}
```

- [ ] **Step 4: Thin facets (best-effort JSON stub)**

```typescript
export async function runFacetsStage(ctx: JobContext, graphDir: string): Promise<string> {
  const out = join(ctx.outDir, "facet.json");
  const payload = {
    repo: ctx.repo,
    owner: ctx.owner,
    sha: ctx.sha,
    graphDir,
    note: "v1 facets are thin; cluster supplements optional later",
  };
  await Bun.write(out, JSON.stringify(payload, null, 2));
  return out;
}
```

- [ ] **Step 5: Manual smoke on a tiny public checkout (optional) + commit**

```bash
git add scripts/codebase-brain/src/stages/clone.ts scripts/codebase-brain/src/stages/pack.ts \
  scripts/codebase-brain/src/stages/analyze.ts scripts/codebase-brain/src/stages/facets.ts
git commit -m "feat(codebase-brain): clone, pack, analyze, facets stages"
```

---

### Task 8: OpenWiki stage (Anthropic)

**Files:**
- Create: `scripts/codebase-brain/src/stages/openwiki.ts`
- Create: `scripts/codebase-brain/src/stages/openwiki.test.ts` (unit: env + copy filter only)

**Interfaces:**
- Consumes: `JobContext` with `anthropicApiKey`
- Produces: `runOpenWiki(ctx) → { wikiDir, wallClockSeconds }`

- [ ] **Step 1: Implement**

```typescript
import { $ } from "bun";
import { join } from "node:path";
import { cp, mkdir, rm } from "node:fs/promises";
import type { JobContext } from "../types";
import { isPublishableWikiRel } from "./strip-side-effects";

export async function runOpenWiki(ctx: JobContext): Promise<{ wikiDir: string; wallClockSeconds: number }> {
  if (!ctx.anthropicApiKey && !process.env.ANTHROPIC_API_KEY) {
    throw new Error("ANTHROPIC_API_KEY required for openwiki narrative");
  }
  const wikiDir = join(ctx.outDir, "openwiki-okf");
  await rm(wikiDir, { recursive: true, force: true });
  await mkdir(wikiDir, { recursive: true });

  const env = {
    ...process.env,
    ANTHROPIC_API_KEY: ctx.anthropicApiKey ?? process.env.ANTHROPIC_API_KEY!,
    OPENWIKI_PROVIDER: "anthropic",
    OPENWIKI_OKF: "1",
    // Pin when known; openwiki default is acceptable for v1
    ...(process.env.OPENWIKI_MODEL_ID
      ? { OPENWIKI_MODEL_ID: process.env.OPENWIKI_MODEL_ID }
      : {}),
  };

  const started = Date.now();
  const logPath = join(wikiDir, "_run.log");
  const res = await $`openwiki code --update -p`.cwd(ctx.workDir).env(env).nothrow();
  await Bun.write(logPath, res.stdout.toString() + res.stderr.toString());
  if (res.exitCode !== 0) {
    throw new Error(`openwiki failed (${res.exitCode}); see ${logPath}`);
  }
  const srcWiki = join(ctx.workDir, "openwiki");
  // Copy only publishable markdown
  const { readdir } = await import("node:fs/promises");
  async function walk(dir: string, base = ""): Promise<void> {
    let entries: string[] = [];
    try {
      entries = await readdir(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const rel = base ? `${base}/${name}` : name;
      const abs = join(dir, name);
      const st = await Bun.file(abs).exists();
      // use stat via $ or fs
      const { stat } = await import("node:fs/promises");
      const s = await stat(abs);
      if (s.isDirectory()) {
        await walk(abs, rel);
      } else if (isPublishableWikiRel(rel)) {
        const dest = join(wikiDir, rel);
        await mkdir(join(dest, ".."), { recursive: true });
        await cp(abs, dest);
      }
    }
  }
  await walk(srcWiki);
  return { wikiDir, wallClockSeconds: Math.round((Date.now() - started) / 1000) };
}
```

- [ ] **Step 2: Unit-test `isPublishableWikiRel` integration in copy list; commit**

```bash
git add scripts/codebase-brain/src/stages/openwiki.ts
git commit -m "feat(codebase-brain): openwiki Anthropic narrative stage"
```

---

### Task 9: R2 graph publish

**Files:**
- Create: `scripts/codebase-brain/src/publish/r2-graph.ts`
- Create: `scripts/codebase-brain/src/publish/r2-graph.test.ts`

**Interfaces:**
- Produces: `buildGraphRef(ctx, graphDigest)`, `publishGraph(ctx, tarballPath, graphDigest)`  
- Dry-run: write `graph-ref.json` + skip upload when `ctx.dryRun` or missing R2 creds

```typescript
export function buildGraphRef(ctx: JobContext, graphDigest: string): GraphRef {
  const key = `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/${ctx.sha}.tgz`;
  return {
    owner: ctx.owner,
    repo: ctx.repo,
    sha: ctx.sha,
    graphDigest,
    r2Uri: `r2://${ctx.r2Bucket}/${key}`,
    latestUri: `r2://${ctx.r2Bucket}/${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest`,
    intent:
      "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later",
  };
}
```

Use `@aws-sdk/client-s3` **or** `aws s3 cp` with `AWS_ENDPOINT_URL` for R2. Prefer SDK in package.json:

```bash
cd scripts/codebase-brain && bun add @aws-sdk/client-s3
```

Upload: sha object immutable; `…/latest` + `…/latest.json` (graph-ref) only after success. On `dryRun`, write `outDir/graph-ref.json` only.

```bash
git commit -m "feat(codebase-brain): R2 graph tarball + graph-ref publish"
```

---

### Task 10: Brain PR publisher

**Files:**
- Create: `scripts/codebase-brain/src/publish/brain-pr.ts`

**Interfaces:**
- Consumes: normalized `outDir/brain-docs/{repo}/**`
- Produces: PR on `second-brain` branch `automation/brain-{repo}`

```typescript
// Outline — implement fully in task:
// 1. clone/fetch second-brain into workRoot/brain
// 2. checkout -B automation/brain-{repo}
// 3. copy brain-docs/{repo} → docs/codebases/{repo}/
// 4. copy sbom.cdx.json + facet.json + graph-ref.json under docs/codebases/{repo}/_meta/
// 5. git add/commit/push
// 6. gh pr create --fill or update existing (never auto-merge)
```

Reuse patterns from `scripts/repomix-pack/src/git-pr.ts` (`commitToBranch`, `openOrUpdatePr`) where practical — copy adapted helpers into `brain-pr.ts` rather than coupling HM launchd paths.

Dry-run: print file list, no push.

```bash
git commit -m "feat(codebase-brain): publish normalized docs via brain PR"
```

---

### Task 11: Wire orchestrator (`phase 1|2|all`)

**Files:**
- Modify: `scripts/codebase-brain/src/index.ts`

**Interfaces:**
- Produces: end-to-end `main()` calling stages in order; write `outDir/manifest.json` with digests + skip decision

- [ ] **Step 1: Implement run pipeline**

```typescript
export async function runJob(ctx: JobContext): Promise<void> {
  await mkdir(ctx.outDir, { recursive: true });
  await cloneAtSha(ctx);
  const { packHash } = await runPackStage(ctx);
  const { graphDigest, tarballPath } = await runAnalyzeStage(ctx);
  await runFacetsStage(ctx, join(ctx.workDir, ".gitnexus"));
  const { sbomPath, sbomDigest } = await runSbom(ctx);
  const digests = {
    packHash,
    graphDigest,
    sbomDigest,
    templateVersion: TEMPLATE_VERSION,
  };
  const prev = await loadPreviousDigests(ctx); // from R2 latest.json or local marker
  const graph = buildGraphRef(ctx, graphDigest);
  await Bun.write(join(ctx.outDir, "graph-ref.json"), JSON.stringify(graph, null, 2));
  await publishGraph(ctx, tarballPath, graphDigest);

  const skip = shouldSkipLlm(digests, prev);
  await Bun.write(
    join(ctx.outDir, "manifest.json"),
    JSON.stringify({ digests, skipLlm: skip, graph }, null, 2),
  );

  if (ctx.phase === 1) return;
  if (skip) {
    console.log("skip LLM: digests unchanged");
    return;
  }

  const { wikiDir } = await runOpenWiki(ctx);
  await normalizeWikiDir(wikiDir, ctx, digests, graph);
  await writeInventoryPage(ctx, sbomPath, digests, graph);
  await publishBrainPr(ctx);
}
```

Implement `loadPreviousDigests` as: read `outDir` marker in dry-run; in prod fetch `r2://…/latest.json`.

- [ ] **Step 2: Local dry-run phase 1 on moneta (no Anthropic)**

```bash
export GH_TOKEN=…   # or gh auth
cd scripts/codebase-brain
bun run src/index.ts --repo moneta --sha "$(git ls-remote https://github.com/nwlnexus/moneta.git HEAD | cut -f1)" \
  --phase 1 --dry-run
```

Expected: `out/.../sbom.cdx.json`, `graph-*.tgz`, `graph-ref.json`, `manifest.json`; no openwiki.

- [ ] **Step 3: Local phase 2 / all with Anthropic (moneta)**

```bash
export ANTHROPIC_API_KEY="$(op read op://Dev/docs-api-key/credential)" # or equivalent
bun run src/index.ts --repo moneta --sha <sha> --phase all --dry-run
```

Expected: `openwiki-okf/`, `brain-docs/moneta/*.md` with nwl fields, `tech-inventory.md`; dry-run skips push.

- [ ] **Step 4: Commit**

```bash
git add scripts/codebase-brain/src/index.ts
git commit -m "feat(codebase-brain): wire phase 1–2 Job orchestrator"
```

---

### Task 12: Job Containerfile

**Files:**
- Create: `scripts/codebase-brain/Containerfile`

```dockerfile
FROM oven/bun:1.2-debian
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl tar gzip \
 && rm -rf /var/lib/apt/lists/*
# Install CLIs — pin versions in build args
ARG REPOMIX_VERSION=latest
ARG GITNEXUS_VERSION=latest
ARG OPENWIKI_VERSION=0.2.0
RUN npm install -g repomix@${REPOMIX_VERSION} gitnexus@${GITNEXUS_VERSION} openwiki@${OPENWIKI_VERSION}
# syft
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
WORKDIR /app
COPY package.json bun.lock tsconfig.json ./
COPY src ./src
COPY ../../modules/repomix/repomix.config.json /etc/codebase-brain/repomix.config.json
RUN bun install --frozen-lockfile
ENV REPOMIX_CONFIG=/etc/codebase-brain/repomix.config.json
ENTRYPOINT ["bun", "run", "src/index.ts"]
```

Note: Docker `COPY ../../modules` may need build context at repo root:

```bash
docker build -f scripts/codebase-brain/Containerfile -t codebase-brain:dev .
```

Adjust Containerfile `COPY` paths for root context. Verify:

```bash
docker run --rm codebase-brain:dev which repomix gitnexus openwiki syft
docker run --rm codebase-brain:dev --help || true
```

```bash
git commit -m "feat(codebase-brain): add Job Containerfile with required CLIs"
```

---

### Task 13: olympus-gitops checklist (external)

**Files:**
- Create: `docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md` (in this repo, executed in olympus-gitops)

Document exact resources to add in olympus-gitops (do not invent cluster YAML here beyond the checklist):

1. Namespace `codebase-brain` (or agreed name)
2. ExternalSecrets: `ANTHROPIC_API_KEY`, GitHub App creds, R2 access key, Slack webhook
3. EventSource: GitHub org webhook, signature verify, `push` to `main`
4. Sensor → Workflow with mutex `brain-{owner}-{repo}`, coalesce to latest sha
5. Allowlist ConfigMap generated from `modules/repomix/repos.toml` personal group only
6. Workflow steps: pull Job image → `bun … --owner --repo --sha --phase all`
7. Notify on failure

- [ ] **Step: Commit checklist + link from parent spec §10**

```bash
git add docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md
git commit -m "docs: Argo/olympus-gitops checklist for codebase-brain Job"
```

---

### Task 14: Docs + README for the Job

**Files:**
- Create: `scripts/codebase-brain/README.md`
- Modify: `docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md` §10 — note provisional brain repo `second-brain`

README must cover: local dry-run, required env vars, phase flags, openwiki side-effect stripping, Anthropic-only narrative.

```bash
git commit -m "docs(codebase-brain): Job README and brain repo provisional choice"
```

---

## Spec coverage (self-review)

| Spec requirement | Task(s) |
| --- | --- |
| Job CLIs: repomix, gitnexus, openwiki, syft | 12, 7, 8, 3 |
| Phase 1: pack + analyze + SBOM + facets + R2 | 3, 7, 9, 11 |
| Phase 2: openwiki Anthropic + inventory + normalize + brain PR | 4, 5, 6, 8, 10, 11 |
| Skip LLM on digest match | 2, 11 |
| Strip AGENTS/CLAUDE/workflows | 6, 8 |
| OKF + nwl Zod | 5 |
| Graph refs / contract C (publish only) | 9 |
| Syft inventory never LLM | 4 |
| Serialize / mutex (Argo) | 13 |
| Moneta / shared MCP | **Deferred** (phases 3–4) |

## Placeholder scan

No TBD steps; brain repo name locked provisionally as `second-brain` (override via `--brain-repo`). R2 bucket default `nwl-codebase-brain` overridable via `BRAIN_R2_BUCKET`.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-17-codebase-brain-job-phases-1-2.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with executing-plans checkpoints  

Which approach?
