import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { JobContext } from "../types";
import {
  brainBranchName,
  brainRepoDir,
  brainRepoSlug,
  buildPrBody,
  buildPrTitle,
  collectPublishCopies,
  formatDryRunLines,
} from "./brain-pr";

const baseCtx: JobContext = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123def4567890",
  workDir: "/tmp/codebase-brain-job/repos/nwlnexus/moneta",
  outDir: "/tmp/out",
  packPath: ".llm/repomix.xml",
  configPath: "/tmp/config.json",
  brainRepo: "second-brain",
  brainContentRoot: "docs/codebases",
  r2Bucket: "nwl-codebase-brain",
  r2Prefix: "graphs",
  dryRun: false,
  phase: "all",
};

describe("brainBranchName", () => {
  test("derives automation branch from repo name", () => {
    expect(brainBranchName("moneta")).toBe("automation/brain-moneta");
    expect(brainBranchName("nix-darwin-hm")).toBe("automation/brain-nix-darwin-hm");
  });
});

describe("brainRepoDir", () => {
  test("resolves workRoot/brain from workDir", () => {
    expect(brainRepoDir(baseCtx)).toBe("/tmp/codebase-brain-job/brain");
  });
});

describe("brainRepoSlug", () => {
  test("uses owner and brainRepo", () => {
    expect(brainRepoSlug(baseCtx)).toBe("nwlnexus/second-brain");
  });
});

describe("buildPrTitle", () => {
  test("summarizes repo and short sha", () => {
    expect(buildPrTitle(baseCtx)).toBe(
      "chore(brain): refresh nwlnexus/moneta docs @ abc123d",
    );
  });
});

describe("buildPrBody", () => {
  test("includes repo, sha, and branch", () => {
    const body = buildPrBody(baseCtx);
    expect(body).toContain("nwlnexus/moneta");
    expect(body).toContain("abc123def4567890");
    expect(body).toContain("automation/brain-moneta");
  });
});

describe("collectPublishCopies", () => {
  test("preserves nested subdirs so same leaf names map to distinct destinations", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-brain-pr-"));
    const outDir = join(root, "out");
    const brainDocs = join(outDir, "brain-docs", baseCtx.repo);
    await mkdir(join(brainDocs, "a"), { recursive: true });
    await mkdir(join(brainDocs, "b"), { recursive: true });
    await writeFile(join(brainDocs, "a", "overview.md"), "# A\n");
    await writeFile(join(brainDocs, "b", "overview.md"), "# B\n");
    await writeFile(join(outDir, "sbom.cdx.json"), "{}");
    await writeFile(join(outDir, "facet.json"), "{}");
    await writeFile(join(outDir, "graph-ref.json"), "{}");

    const ctx = { ...baseCtx, outDir };
    const copies = await collectPublishCopies(ctx);

    const dests = copies.map((c) => c.destRepoPath);
    expect(dests).toContain("docs/codebases/moneta/a/overview.md");
    expect(dests).toContain("docs/codebases/moneta/b/overview.md");
    expect(dests).toContain("docs/codebases/moneta/_meta/sbom.cdx.json");
    expect(dests).toContain("docs/codebases/moneta/_meta/facet.json");
    expect(dests).toContain("docs/codebases/moneta/_meta/graph-ref.json");

    const overviewDests = dests.filter((d) => d.endsWith("overview.md"));
    expect(overviewDests).toHaveLength(2);
    expect(new Set(overviewDests).size).toBe(2);

    await rm(root, { recursive: true, force: true });
  });

  test("skips missing meta artifacts", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-brain-pr-meta-"));
    const outDir = join(root, "out");
    const brainDocs = join(outDir, "brain-docs", baseCtx.repo);
    await mkdir(brainDocs, { recursive: true });
    await writeFile(join(brainDocs, "overview.md"), "# root\n");
    await writeFile(join(outDir, "graph-ref.json"), "{}");

    const ctx = { ...baseCtx, outDir };
    const copies = await collectPublishCopies(ctx);

    const dests = copies.map((c) => c.destRepoPath);
    expect(dests).toContain("docs/codebases/moneta/overview.md");
    expect(dests).toContain("docs/codebases/moneta/_meta/graph-ref.json");
    expect(dests).not.toContain("docs/codebases/moneta/_meta/sbom.cdx.json");
    expect(dests).not.toContain("docs/codebases/moneta/_meta/facet.json");

    await rm(root, { recursive: true, force: true });
  });
});

describe("formatDryRunLines", () => {
  test("lists source to dest mappings", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-brain-pr-dry-"));
    const outDir = join(root, "out");
    const brainDocs = join(outDir, "brain-docs", baseCtx.repo, "services", "hermes");
    await mkdir(brainDocs, { recursive: true });
    await writeFile(join(brainDocs, "overview.md"), "# Hermes\n");

    const ctx = { ...baseCtx, outDir };
    const copies = await collectPublishCopies(ctx);
    const lines = formatDryRunLines(copies);

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("overview.md");
    expect(lines[0]).toContain("-> docs/codebases/moneta/services/hermes/overview.md");

    await rm(root, { recursive: true, force: true });
  });
});
