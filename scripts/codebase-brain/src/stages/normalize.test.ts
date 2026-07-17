import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, readFile, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { stampNwlExtensions, splitFrontmatter, normalizeWikiDir } from "./normalize";
import { NwlDocSchema } from "../schema/frontmatter";
import type { Digests, GraphRef, JobContext } from "../types";

const ctx: JobContext = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123",
  workDir: "/tmp/work",
  outDir: "/tmp/out",
  packPath: "/tmp/pack.xml",
  configPath: "/tmp/config.json",
  brainRepo: "brain",
  brainContentRoot: "docs/codebases",
  r2Bucket: "bucket",
  r2Prefix: "graphs",
  dryRun: false,
  phase: "2",
};

const digests: Digests = {
  packHash: "sha256:1",
  graphDigest: "sha256:2",
  sbomDigest: "sha256:3",
  templateVersion: "openwiki-0.2",
};

const graph: GraphRef = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123",
  graphDigest: "sha256:2",
  r2Uri: "r2://graphs/nwlnexus/moneta/abc123",
  latestUri: "r2://graphs/nwlnexus/moneta/latest",
  intent: "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later",
};

describe("stampNwlExtensions", () => {
  test("stamped doc parses via NwlDocSchema and contains graphUri", () => {
    const raw = `---
type: Repository Overview
title: moneta
description: Overview
tags:
  - docs
---

# Overview
`;
    const stamped = stampNwlExtensions(raw, "overview.md", ctx, digests, graph);
    const { fm } = splitFrontmatter(stamped);
    const parsed = NwlDocSchema.parse(fm);
    expect(parsed.source.graphUri).toBe(graph.r2Uri);
    expect(stamped).toContain("# Overview");
  });
});

describe("normalizeWikiDir", () => {
  test("writes stamped docs and skips underscore paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-normalize-"));
    const wikiDir = join(root, "wiki");
    const outDir = join(root, "out");
    await mkdir(wikiDir, { recursive: true });
    await writeFile(
      join(wikiDir, "overview.md"),
      `---
title: moneta
---

# Overview
`,
    );
    await writeFile(join(wikiDir, "_plan.md"), "# plan\n");
    await mkdir(join(wikiDir, "_scratch"), { recursive: true });
    await writeFile(join(wikiDir, "_scratch", "notes.md"), "# notes\n");

    const jobCtx = { ...ctx, outDir };
    const written = await normalizeWikiDir(wikiDir, jobCtx, digests, graph);

    expect(written).toHaveLength(1);
    const content = await readFile(written[0]!, "utf8");
    const { fm } = splitFrontmatter(content);
    expect(NwlDocSchema.safeParse(fm).success).toBe(true);
    expect((fm as { source: { graphUri: string } }).source.graphUri).toBe(graph.r2Uri);

    await rm(root, { recursive: true, force: true });
  });

  test("preserves nested subdirs so same leaf names do not collide", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-normalize-nested-"));
    const wikiDir = join(root, "wiki");
    const outDir = join(root, "out");
    await mkdir(join(wikiDir, "a"), { recursive: true });
    await mkdir(join(wikiDir, "b"), { recursive: true });
    await writeFile(
      join(wikiDir, "a", "overview.md"),
      `---
title: Service A
---

# A Overview
`,
    );
    await writeFile(
      join(wikiDir, "b", "overview.md"),
      `---
title: Service B
---

# B Overview
`,
    );

    const jobCtx = { ...ctx, outDir };
    const written = await normalizeWikiDir(wikiDir, jobCtx, digests, graph);

    expect(written).toHaveLength(2);
    const destA = join(outDir, "brain-docs", ctx.repo, "a", "overview.md");
    const destB = join(outDir, "brain-docs", ctx.repo, "b", "overview.md");
    expect(written).toContain(destA);
    expect(written).toContain(destB);

    const contentA = await readFile(destA, "utf8");
    const contentB = await readFile(destB, "utf8");
    const { fm: fmA } = splitFrontmatter(contentA);
    const { fm: fmB } = splitFrontmatter(contentB);

    expect(NwlDocSchema.parse(fmA).slug).toBe(`${ctx.repo}/a/overview`);
    expect(NwlDocSchema.parse(fmB).slug).toBe(`${ctx.repo}/b/overview`);
    expect(fmA).not.toEqual(fmB);
    expect(contentA).toContain("# A Overview");
    expect(contentB).toContain("# B Overview");

    await rm(root, { recursive: true, force: true });
  });
});
