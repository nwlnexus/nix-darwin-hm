# Codebase Brain — OpenWiki Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce side-by-side documentation artifacts (openwiki OKF vs custom slotted docs) plus dry-run Moneta nuggets for `moneta` and `olympus-sdk`, then a scorecard that recommends adopt / keep / hybrid for openwiki in the July 15 brain pipeline.

**Architecture:** A throwaway spike workspace under `/tmp/codebase-brain-openwiki-spike/`. Shell + Bun/TS harness clones each repo, runs shared producers (repomix, gitnexus, syft), then two doc paths (Path O = openwiki code mode via Studio Ollama; Path C = a small Bun generator), emits dry-run Moneta nugget JSON (no production writes), and fills scorecards. Nothing lands in source repos or production Moneta.

**Tech Stack:** Bun/TS, repomix, gitnexus (`npx gitnexus`), syft (CycloneDX), openwiki (`npm i -g openwiki`) via `openai-compatible` provider → Studio Ollama, `gh`/`git`.

## Global Constraints

- Spike root: `/tmp/codebase-brain-openwiki-spike/` (all writes stay here; override with `SPIKE_ROOT`).
- Repos: `nwlnexus/moneta` and `nwlnexus/olympus-sdk`, cloned over `git@github.com:`.
- LLM: Studio Ollama over tailnet for BOTH paths. Base URL env `STUDIO_OLLAMA_URL`, default `http://ai-hub.raptor-mimosa.ts.net:11434` (confirm this is the Mac Studio host, not the mnemosyne hub, before relying on results).
- OpenWiki wiring: `OPENWIKI_PROVIDER=openai-compatible`, `OPENAI_COMPATIBLE_BASE_URL=$STUDIO_OLLAMA_URL/v1`, `OPENAI_COMPATIBLE_API_KEY=ollama`, `OPENWIKI_MODEL_ID=qwen3.6:27b-mlx` (fallback `qwen2.5:7b-instruct`).
- OpenWiki **code mode only** — never `openwiki personal`.
- Syft owns dependency truth. No LLM-authored dependency rows in any inventory doc.
- No writes to production Moneta (`mem.nwlnexus.io`). Nuggets are emitted as JSON files only.
- No commits to source repos, no brain PRs, no Argo.
- repomix shared ignores include `.llm/**` and `.gitnexus/**` (from `modules/repomix/repomix.config.json`).
- Do not flip the parent spec's openwiki rejection or issue #40 during the spike — only after the recommendation is accepted.

---

### Task 1: Spike workspace bootstrap

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/bin/00-bootstrap.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `$SPIKE_ROOT/repos/{moneta,olympus-sdk}` clones; `$SPIKE_ROOT/artifacts/{moneta,olympus-sdk}/` dirs; `$SPIKE_ROOT/.env.spike` with shared env.

- [ ] **Step 1: Write the bootstrap script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SPIKE_ROOT="${SPIKE_ROOT:-/tmp/codebase-brain-openwiki-spike}"
STUDIO_OLLAMA_URL="${STUDIO_OLLAMA_URL:-http://ai-hub.raptor-mimosa.ts.net:11434}"
REPOS=(moneta olympus-sdk)
OWNER=nwlnexus

mkdir -p "$SPIKE_ROOT/bin" "$SPIKE_ROOT/repos" "$SPIKE_ROOT/artifacts"

cat > "$SPIKE_ROOT/.env.spike" <<EOF
export SPIKE_ROOT="$SPIKE_ROOT"
export STUDIO_OLLAMA_URL="$STUDIO_OLLAMA_URL"
export OPENWIKI_PROVIDER=openai-compatible
export OPENAI_COMPATIBLE_BASE_URL="$STUDIO_OLLAMA_URL/v1"
export OPENAI_COMPATIBLE_API_KEY=ollama
export OPENWIKI_MODEL_ID=qwen3.6:27b-mlx
export OPENWIKI_MODEL_ID_FALLBACK=qwen2.5:7b-instruct
EOF

for r in "${REPOS[@]}"; do
  mkdir -p "$SPIKE_ROOT/artifacts/$r/graph"
  if [ ! -d "$SPIKE_ROOT/repos/$r/.git" ]; then
    git clone --depth 1 "git@github.com:$OWNER/$r.git" "$SPIKE_ROOT/repos/$r"
  else
    git -C "$SPIKE_ROOT/repos/$r" fetch origin --depth 1
    git -C "$SPIKE_ROOT/repos/$r" reset --hard @{u}
  fi
  git -C "$SPIKE_ROOT/repos/$r" rev-parse HEAD > "$SPIKE_ROOT/artifacts/$r/sha.txt"
done

echo "bootstrap OK: $SPIKE_ROOT"
```

- [ ] **Step 2: Run it**

Run: `bash /tmp/codebase-brain-openwiki-spike/bin/00-bootstrap.sh`
Expected: `bootstrap OK: /tmp/codebase-brain-openwiki-spike`, and both clones exist.

- [ ] **Step 3: Verify clones and env**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && ls "$SPIKE_ROOT/repos" && cat "$SPIKE_ROOT"/artifacts/*/sha.txt`
Expected: `moneta` and `olympus-sdk` listed; two 40-char SHAs printed.

---

### Task 2: Shared producers (repomix + gitnexus + syft)

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/bin/10-producers.sh`
- Reference: `modules/repomix/repomix.config.json` (shared repomix config in nix-darwin-hm)

**Interfaces:**
- Consumes: `$SPIKE_ROOT/repos/<repo>` (Task 1).
- Produces per repo: `artifacts/<repo>/repomix.xml`, `artifacts/<repo>/graph/` (gitnexus `.gitnexus/`), `artifacts/<repo>/sbom.cdx.json`.

- [ ] **Step 1: Ensure syft is available**

Run: `command -v syft || brew install syft`
Expected: a `syft` path prints (install if missing).

- [ ] **Step 2: Write the producers script**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${SPIKE_ROOT:-/tmp/codebase-brain-openwiki-spike}/.env.spike"

REPOMIX_CONFIG="${REPOMIX_CONFIG:-$HOME/projects/personal/nix-darwin-hm/modules/repomix/repomix.config.json}"

for r in moneta olympus-sdk; do
  SRC="$SPIKE_ROOT/repos/$r"
  OUT="$SPIKE_ROOT/artifacts/$r"

  # 1) repomix pack (shared config; output forced into artifacts)
  ( cd "$SRC" && npx --yes repomix --config "$REPOMIX_CONFIG" \
      --output "$OUT/repomix.xml" )

  # 2) gitnexus analyze (writes .gitnexus/ in the repo; copy into artifacts)
  ( cd "$SRC" && npx --yes gitnexus analyze )
  rm -rf "$OUT/graph" && cp -R "$SRC/.gitnexus" "$OUT/graph"

  # 3) syft SBOM (CycloneDX)
  syft "dir:$SRC" -o cyclonedx-json > "$OUT/sbom.cdx.json"

  echo "producers OK: $r"
done
```

- [ ] **Step 3: Run it**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && bash "$SPIKE_ROOT/bin/10-producers.sh"`
Expected: `producers OK: moneta` and `producers OK: olympus-sdk`.

- [ ] **Step 4: Verify artifacts exist and SBOM is valid JSON**

Run: `for r in moneta olympus-sdk; do echo "== $r =="; ls -la "$SPIKE_ROOT/artifacts/$r/repomix.xml" "$SPIKE_ROOT/artifacts/$r/sbom.cdx.json"; jq '.bomFormat,(.components|length)' "$SPIKE_ROOT/artifacts/$r/sbom.cdx.json"; done`
Expected: files present; `"CycloneDX"` printed and a non-negative component count for each repo.

---

### Task 3: Studio Ollama connectivity + openwiki install

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/bin/20-llm-check.sh`

**Interfaces:**
- Consumes: `$SPIKE_ROOT/.env.spike`.
- Produces: `artifacts/_llm/model.txt` (resolved model id that answered), verified openwiki binary.

- [ ] **Step 1: Ensure openwiki is installed**

Run: `command -v openwiki || npm install -g openwiki@latest`
Expected: an `openwiki` path prints.

- [ ] **Step 2: Write the connectivity check**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${SPIKE_ROOT:-/tmp/codebase-brain-openwiki-spike}/.env.spike"
mkdir -p "$SPIKE_ROOT/artifacts/_llm"

pick_model() {
  for m in "$OPENWIKI_MODEL_ID" "$OPENWIKI_MODEL_ID_FALLBACK"; do
    if curl -sf "$STUDIO_OLLAMA_URL/api/tags" | jq -e --arg m "$m" \
        '.models[]?.name | select(. == $m or startswith($m))' >/dev/null; then
      echo "$m"; return 0
    fi
  done
  return 1
}

MODEL="$(pick_model)" || { echo "ERROR: neither model present on $STUDIO_OLLAMA_URL"; exit 1; }
echo "$MODEL" > "$SPIKE_ROOT/artifacts/_llm/model.txt"

# Sanity: a one-shot chat completion via the OpenAI-compatible surface.
curl -sf "$OPENAI_COMPATIBLE_BASE_URL/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg m "$MODEL" '{model:$m,messages:[{role:"user",content:"reply with the single word: ok"}],stream:false}')" \
  | jq -e '.choices[0].message.content' >/dev/null

echo "llm OK: $MODEL"
```

- [ ] **Step 3: Run it**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && bash "$SPIKE_ROOT/bin/20-llm-check.sh"`
Expected: `llm OK: qwen3.6:27b-mlx` (or the fallback). If it errors, confirm `STUDIO_OLLAMA_URL` points at the Mac Studio and the model is pulled (`ollama pull qwen3.6:27b-mlx` on the Studio).

---

### Task 4: Path O — openwiki code mode (OKF)

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/bin/30-path-o.sh`

**Interfaces:**
- Consumes: `$SPIKE_ROOT/repos/<repo>`, resolved model (Task 3).
- Produces per repo: `artifacts/<repo>/openwiki-okf/` (copied OKF wiki), `artifacts/<repo>/openwiki-okf/_raw-tree.txt` (record of what openwiki generated).

- [ ] **Step 1: Write the Path O script**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${SPIKE_ROOT:-/tmp/codebase-brain-openwiki-spike}/.env.spike"
MODEL="$(cat "$SPIKE_ROOT/artifacts/_llm/model.txt")"
export OPENWIKI_MODEL_ID="$MODEL"
export OPENWIKI_OKF=1   # emit OKF frontmatter

for r in moneta olympus-sdk; do
  SRC="$SPIKE_ROOT/repos/$r"
  OUT="$SPIKE_ROOT/artifacts/$r/openwiki-okf"
  mkdir -p "$OUT"

  # Code mode, one-shot, non-interactive. --update also inits if no wiki exists.
  ( cd "$SRC" && openwiki code --update --print --okf ) \
    | tee "$OUT/_run.log"

  # Capture what openwiki produced, then copy the wiki out of the repo clone.
  ( cd "$SRC" && git status --porcelain ) > "$OUT/_raw-tree.txt" || true
  if [ -d "$SRC/openwiki" ]; then
    cp -R "$SRC/openwiki/." "$OUT/"
  fi

  echo "path-o OK: $r"
done
```

- [ ] **Step 2: Run it**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && bash "$SPIKE_ROOT/bin/30-path-o.sh"`
Expected: `path-o OK: moneta` and `path-o OK: olympus-sdk`.

- [ ] **Step 3: Verify OKF output exists with frontmatter**

Run: `for r in moneta olympus-sdk; do echo "== $r =="; find "$SPIKE_ROOT/artifacts/$r/openwiki-okf" -name '*.md' | head; grep -l '^type:' "$SPIKE_ROOT/artifacts/$r/openwiki-okf"/*.md 2>/dev/null | head; done`
Expected: at least one `.md` per repo; at least one file with a `type:` frontmatter key (OKF). For `olympus-sdk`, note whether packages get distinct pages/sections (record in the scorecard).

---

### Task 5: Path C — custom slotted docs (Bun/TS)

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/gen/package.json`
- Create: `/tmp/codebase-brain-openwiki-spike/gen/src/llm.ts`
- Create: `/tmp/codebase-brain-openwiki-spike/gen/src/inventory.ts`
- Create: `/tmp/codebase-brain-openwiki-spike/gen/src/path-c.ts`
- Test: `/tmp/codebase-brain-openwiki-spike/gen/src/inventory.test.ts`

**Interfaces:**
- Consumes: `artifacts/<repo>/{repomix.xml,sbom.cdx.json}`, resolved model, `STUDIO_OLLAMA_URL`.
- Produces per repo: `artifacts/<repo>/custom-mdx/overview.md`, `artifacts/<repo>/custom-mdx/tech-inventory.md`.
- Exposes for Task 6: `renderInventory(sbom): string`, `chatComplete(baseUrl, model, prompt): Promise<string>`.

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "spike-gen",
  "private": true,
  "type": "module",
  "scripts": { "test": "bun test" }
}
```

- [ ] **Step 2: Write the failing test for the deterministic inventory renderer**

```ts
// gen/src/inventory.test.ts
import { expect, test } from "bun:test";
import { renderInventory } from "./inventory";

test("renderInventory lists components from a CycloneDX SBOM, no invention", () => {
  const sbom = {
    bomFormat: "CycloneDX",
    components: [
      { name: "hono", version: "4.6.0", type: "library" },
      { name: "zod", version: "3.23.8", type: "library" },
    ],
  };
  const md = renderInventory(sbom);
  expect(md).toContain("| hono | 4.6.0 |");
  expect(md).toContain("| zod | 3.23.8 |");
  expect(md).toContain("Components: 2");
  // must not fabricate rows
  expect(md).not.toContain("express");
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /tmp/codebase-brain-openwiki-spike/gen && bun test`
Expected: FAIL — `Cannot find module "./inventory"`.

- [ ] **Step 4: Implement the inventory renderer**

```ts
// gen/src/inventory.ts
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /tmp/codebase-brain-openwiki-spike/gen && bun test`
Expected: PASS (1 pass).

- [ ] **Step 6: Write the LLM client**

```ts
// gen/src/llm.ts
export async function chatComplete(
  baseUrl: string,
  model: string,
  prompt: string,
): Promise<string> {
  const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      stream: false,
      messages: [
        { role: "system", content: "You are a precise technical writer. Use only the provided context. Do not invent dependencies, files, or APIs." },
        { role: "user", content: prompt },
      ],
    }),
  });
  if (!res.ok) throw new Error(`LLM ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { choices: { message: { content: string } }[] };
  return json.choices[0]?.message?.content ?? "";
}
```

- [ ] **Step 7: Write the Path C generator**

```ts
// gen/src/path-c.ts
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { renderInventory, type Sbom } from "./inventory";
import { chatComplete } from "./llm";

const SPIKE_ROOT = process.env.SPIKE_ROOT ?? "/tmp/codebase-brain-openwiki-spike";
const BASE = process.env.OPENAI_COMPATIBLE_BASE_URL!;
const MODEL = readFileSync(`${SPIKE_ROOT}/artifacts/_llm/model.txt`, "utf8").trim();
const REPOS = ["moneta", "olympus-sdk"];

function frontmatter(repo: string, docType: string, title: string, description: string): string {
  const sha = readFileSync(`${SPIKE_ROOT}/artifacts/${repo}/sha.txt`, "utf8").trim();
  return [
    "---",
    `type: ${docType === "overview" ? "Repository Overview" : "Technology Inventory"}`,
    `title: ${title}`,
    `description: ${description}`,
    "tags: [codebase_doc]",
    `timestamp: ${new Date().toISOString()}`,
    `docType: ${docType}`,
    `repo: ${repo}`,
    "owner: nwlnexus",
    `slug: ${repo}/${docType}`,
    "source:",
    `  sha: ${sha}`,
    "  templateVersion: custom-spike-1",
    `brainPath: docs/codebases/${repo}/${docType}.md`,
    "status: generated",
    "---",
    "",
  ].join("\n");
}

for (const repo of REPOS) {
  const outDir = `${SPIKE_ROOT}/artifacts/${repo}/custom-mdx`;
  mkdirSync(outDir, { recursive: true });

  // Deterministic inventory (syft only — no LLM).
  const sbom = JSON.parse(readFileSync(`${SPIKE_ROOT}/artifacts/${repo}/sbom.cdx.json`, "utf8")) as Sbom;
  const inv = frontmatter(repo, "inventory", `${repo} — Technology Inventory`, `Dependency inventory for ${repo} (syft/CycloneDX).`) +
    `# ${repo} — Technology Inventory\n\n` + renderInventory(sbom);
  writeFileSync(`${outDir}/tech-inventory.md`, inv);

  // LLM overview from a bounded repomix excerpt (slotted prose only).
  const pack = readFileSync(`${SPIKE_ROOT}/artifacts/${repo}/repomix.xml`, "utf8").slice(0, 60_000);
  const prompt = `Repository: ${repo}\nUsing ONLY this packed source excerpt, write three short markdown sections with headings "## TL;DR", "## Architecture", "## Gotchas". Be concrete and do not invent dependencies.\n\n<pack>\n${pack}\n</pack>`;
  const body = await chatComplete(BASE, MODEL, prompt);
  const overview = frontmatter(repo, "overview", `${repo} — Overview`, `Narrative overview of ${repo}.`) +
    `# ${repo} — Overview\n\n` + body + "\n";
  writeFileSync(`${outDir}/overview.md`, overview);

  console.log(`path-c OK: ${repo}`);
}
```

- [ ] **Step 8: Run the generator**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && cd "$SPIKE_ROOT/gen" && bun run src/path-c.ts`
Expected: `path-c OK: moneta` and `path-c OK: olympus-sdk`.

- [ ] **Step 9: Verify Path C artifacts**

Run: `for r in moneta olympus-sdk; do echo "== $r =="; head -20 "$SPIKE_ROOT/artifacts/$r/custom-mdx/overview.md"; grep -c '^|' "$SPIKE_ROOT/artifacts/$r/custom-mdx/tech-inventory.md"; done`
Expected: overview has OKF+extended frontmatter then `## TL;DR`; inventory has table rows (count ≥ 2 for a repo with deps).

---

### Task 6: Dry-run Moneta nugget generator

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/gen/src/nuggets.ts`
- Test: `/tmp/codebase-brain-openwiki-spike/gen/src/nuggets.test.ts`

**Interfaces:**
- Consumes: `artifacts/<repo>/openwiki-okf/**` (Path O) and `artifacts/<repo>/custom-mdx/**` (Path C).
- Produces per repo: `artifacts/<repo>/moneta-dry-run.openwiki.json`, `artifacts/<repo>/moneta-dry-run.custom.json`.
- Exposes: `nuggetsFromMarkdown(md, {repo, docType, sha, brainPath}): Nugget[]`.

- [ ] **Step 1: Write the failing test**

```ts
// gen/src/nuggets.test.ts
import { expect, test } from "bun:test";
import { nuggetsFromMarkdown } from "./nuggets";

const md = `---
type: Repository Overview
---
# moneta — Overview

## TL;DR
Moneta is a Cloudflare Worker memory backend.

## Architecture
D1 for facts, Vectorize for embeddings.
`;

test("splits by heading into heading-sized nuggets with provenance", () => {
  const n = nuggetsFromMarkdown(md, { repo: "moneta", docType: "overview", sha: "abc123", brainPath: "docs/codebases/moneta/overview.md" });
  expect(n.length).toBe(2); // TL;DR + Architecture (frontmatter + H1 skipped)
  const tldr = n.find((x) => x.metadata.heading === "TL;DR")!;
  expect(tldr.content).toContain("Cloudflare Worker");
  expect(tldr.tags).toContain("kind:codebase_doc");
  expect(tldr.tags).toContain("repo:moneta");
  expect(tldr.metadata.idempotencyKey).toBe("codebase_doc:moneta:abc123:overview:tldr");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /tmp/codebase-brain-openwiki-spike/gen && bun test src/nuggets.test.ts`
Expected: FAIL — `Cannot find module "./nuggets"`.

- [ ] **Step 3: Implement the nugget splitter**

```ts
// gen/src/nuggets.ts
export interface Nugget {
  content: string;
  tags: string[];
  metadata: {
    kind: "codebase_doc";
    repo: string;
    docType: string;
    sha: string;
    heading: string;
    brainPath: string;
    idempotencyKey: string;
  };
}

interface Ctx { repo: string; docType: string; sha: string; brainPath: string }

function stripFrontmatter(md: string): string {
  if (md.startsWith("---")) {
    const end = md.indexOf("\n---", 3);
    if (end !== -1) return md.slice(md.indexOf("\n", end + 1) + 1);
  }
  return md;
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

export function nuggetsFromMarkdown(md: string, ctx: Ctx): Nugget[] {
  const body = stripFrontmatter(md);
  const out: Nugget[] = [];
  // Split on H2 (## ) headings; ignore H1 and preamble.
  const parts = body.split(/\n(?=## )/);
  for (const part of parts) {
    const m = part.match(/^##\s+(.+)\n?([\s\S]*)$/);
    if (!m) continue;
    const heading = m[1].trim();
    const content = m[2].trim();
    if (!content) continue;
    const hslug = slug(heading);
    out.push({
      content,
      tags: ["kind:codebase_doc", `repo:${ctx.repo}`, `docType:${ctx.docType}`, `topic:${hslug}`],
      metadata: {
        kind: "codebase_doc",
        repo: ctx.repo,
        docType: ctx.docType,
        sha: ctx.sha,
        heading,
        brainPath: ctx.brainPath,
        idempotencyKey: `codebase_doc:${ctx.repo}:${ctx.sha}:${ctx.docType}:${hslug}`,
      },
    });
  }
  return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /tmp/codebase-brain-openwiki-spike/gen && bun test src/nuggets.test.ts`
Expected: PASS.

- [ ] **Step 5: Write the dry-run emitter (uses the splitter over both paths)**

```ts
// append to gen/src/nuggets.ts
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";

function walkMd(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) out.push(...walkMd(p));
    else if (e.endsWith(".md")) out.push(p);
  }
  return out;
}

function docTypeFor(file: string): string {
  if (file.includes("inventory")) return "inventory";
  if (file.includes("cluster")) return "cluster";
  return "overview";
}

if (import.meta.main) {
  const root = process.env.SPIKE_ROOT ?? "/tmp/codebase-brain-openwiki-spike";
  for (const repo of ["moneta", "olympus-sdk"]) {
    const sha = readFileSync(`${root}/artifacts/${repo}/sha.txt`, "utf8").trim();
    for (const [path, out] of [
      ["openwiki-okf", "moneta-dry-run.openwiki.json"],
      ["custom-mdx", "moneta-dry-run.custom.json"],
    ] as const) {
      const nuggets: Nugget[] = [];
      for (const f of walkMd(`${root}/artifacts/${repo}/${path}`)) {
        const dt = docTypeFor(f);
        nuggets.push(...nuggetsFromMarkdown(readFileSync(f, "utf8"), {
          repo, docType: dt, sha, brainPath: `docs/codebases/${repo}/${dt}.md`,
        }));
      }
      writeFileSync(`${root}/artifacts/${repo}/${out}`, JSON.stringify(nuggets, null, 2));
      console.log(`nuggets ${repo}/${path}: ${nuggets.length}`);
    }
  }
}
```

- [ ] **Step 6: Run the emitter**

Run: `source /tmp/codebase-brain-openwiki-spike/.env.spike && cd "$SPIKE_ROOT/gen" && bun run src/nuggets.ts`
Expected: printed nugget counts per repo/path; four `moneta-dry-run.*.json` files across the two repos.

- [ ] **Step 7: Verify no production Moneta calls and valid JSON**

Run: `grep -rn "mem.nwlnexus.io\|/capture" /tmp/codebase-brain-openwiki-spike/gen/src || echo "no capture calls"; jq 'length' /tmp/codebase-brain-openwiki-spike/artifacts/*/moneta-dry-run.*.json`
Expected: `no capture calls`; each JSON reports an integer length.

---

### Task 7: Scorecards + recommendation

**Files:**
- Create: `/tmp/codebase-brain-openwiki-spike/artifacts/moneta/scorecard.md`
- Create: `/tmp/codebase-brain-openwiki-spike/artifacts/olympus-sdk/scorecard.md`
- Create: `/tmp/codebase-brain-openwiki-spike/artifacts/scorecard-summary.md`

**Interfaces:**
- Consumes: all artifacts from Tasks 2–6.
- Produces: filled scorecards + a recommendation (adopt / keep / hybrid).

- [ ] **Step 1: Write the per-repo scorecard template (repeat for each repo)**

```markdown
# Scorecard — <repo>

**SHA:** <from artifacts/<repo>/sha.txt>
**LLM:** <from artifacts/_llm/model.txt>

| Dimension | Path O (openwiki OKF) | Path C (custom) | Notes |
| --- | --- | --- | --- |
| Coverage | | | |
| Monorepo shape | | | (olympus-sdk: are packages distinct?) |
| Determinism | | | inventory vs syft components |
| Frontmatter / OKF fit | | | extension fields clean? |
| Moneta fit | | | nugget count + recall-worthiness |
| Cost/ops | | | wall-clock, retries, Ollama quirks |
| Diff friendliness | | | openwiki --update scoping |

**Artifact pointers:** openwiki-okf/, custom-mdx/, moneta-dry-run.*.json
```

- [ ] **Step 2: Fill both scorecards by inspecting artifacts**

Run: `ls -R /tmp/codebase-brain-openwiki-spike/artifacts/moneta /tmp/codebase-brain-openwiki-spike/artifacts/olympus-sdk`
Then read the generated docs and dry-run JSON and fill each cell with observations (not guesses).

- [ ] **Step 3: Write the summary + recommendation**

```markdown
# OpenWiki Spike — Summary

**Recommendation:** <adopt Path O | keep Path C | hybrid>

## Evidence
- moneta: <1-2 lines>
- olympus-sdk (monorepo): <1-2 lines, esp. package discoverability>

## OpenWiki surprises / failures
- <openai-compatible + Studio Ollama behavior, tool-calling, context limits>

## OKF / frontmatter fit
- <does OKF base + nwl extensions work without fighting the tool?>

## Moneta dry-run fit
- <nugget shape, provenance completeness, supersede implications>

## Proposed parent-spec edits (docs/superpowers/specs/2026-07-15-codebase-brain-pipeline-design.md)
- <bullet list mapped to §4.3, §4.4, §5.1; and #40 disposition>
```

- [ ] **Step 4: Verify the decision packet is complete**

Run: `test -s /tmp/codebase-brain-openwiki-spike/artifacts/scorecard-summary.md && grep -q "Recommendation:" /tmp/codebase-brain-openwiki-spike/artifacts/scorecard-summary.md && echo "summary OK"`
Expected: `summary OK`, and both per-repo scorecards have no empty required cells.

---

## Self-Review

**Spec coverage** (against `2026-07-17-codebase-brain-openwiki-spike-design.md`):
- §4/§5/§6 workspace + producers + run sequence → Tasks 1–4.
- Path O openwiki OKF → Task 4. Path C custom → Task 5. Dry-run Moneta → Task 6.
- §7 rubric + §10 success (scorecards, recommendation, monorepo notes, Ollama reliability) → Task 7.
- Guardrails (no prod Moneta, code mode only, syft owns inventory, no source-repo commits) → Global Constraints + Task 6 Step 7 check.
- §9 parent-spec edits → captured as Task 7 Step 3 output (not applied during spike, per constraint).

**Placeholder scan:** Scorecard cells are intentionally blank (filled from observation in Task 7); all code steps contain complete code. No TBD/TODO in harness code.

**Type consistency:** `renderInventory(Sbom)`, `chatComplete(baseUrl, model, prompt)`, `nuggetsFromMarkdown(md, ctx)` and the `Nugget` shape are consistent across Tasks 5–6.
