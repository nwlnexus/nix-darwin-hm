import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { TEMPLATE_VERSION, shouldSkipLlm } from "./digests";
import type { GraphRef, JobContext } from "./types";
import {
  buildContext,
  buildManifest,
  loadPreviousDigests,
  parseDigestsMarker,
  previousDigestsMarkerPath,
  shouldRunLlmSection,
} from "./index";

const baseCtx: JobContext = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123",
  workDir: "/tmp/work",
  outDir: "/tmp/out/nwlnexus/moneta/abc123",
  packPath: ".llm/repomix.xml",
  configPath: "/tmp/config.json",
  brainRepo: "second-brain",
  brainContentRoot: "docs/codebases",
  r2Bucket: "nwl-codebase-brain",
  r2Prefix: "graphs",
  dryRun: true,
  phase: "all",
};

const sampleDigests = {
  packHash: "sha256:pack",
  graphDigest: "sha256:graph",
  sbomDigest: "sha256:sbom",
  templateVersion: TEMPLATE_VERSION,
};

const sampleGraph: GraphRef = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123",
  graphDigest: "sha256:graph",
  r2Uri: "r2://nwl-codebase-brain/graphs/nwlnexus/moneta/abc123.tgz",
  latestUri: "r2://nwl-codebase-brain/graphs/nwlnexus/moneta/latest",
  intent: "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later",
};

describe("buildContext", () => {
  test("defaults phase to all", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc"]);
    expect(ctx.phase).toBe("all");
  });

  test("accepts --phase 1", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "1"]);
    expect(ctx.phase).toBe("1");
  });

  test("accepts --phase 2", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "2"]);
    expect(ctx.phase).toBe("2");
  });

  test("throws when --repo is missing", () => {
    expect(() => buildContext(["--sha", "abc"])).toThrow("--repo and --sha are required");
  });

  test("throws for invalid --phase", () => {
    expect(() =>
      buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "bogus"]),
    ).toThrow("--phase must be 1 | 2 | all");
  });
});

describe("shouldRunLlmSection", () => {
  test("phase 1 never runs LLM section", () => {
    expect(shouldRunLlmSection("1", false)).toBe(false);
    expect(shouldRunLlmSection("1", true)).toBe(false);
  });

  test("phase 2 and all run LLM when not skipping", () => {
    expect(shouldRunLlmSection("2", false)).toBe(true);
    expect(shouldRunLlmSection("all", false)).toBe(true);
  });

  test("skipLlm suppresses LLM section for phase 2 and all", () => {
    expect(shouldRunLlmSection("2", true)).toBe(false);
    expect(shouldRunLlmSection("all", true)).toBe(false);
  });
});

describe("buildManifest", () => {
  test("includes digests, skipLlm, and graph", () => {
    const manifest = buildManifest(sampleDigests, false, sampleGraph);
    expect(manifest).toEqual({
      digests: sampleDigests,
      skipLlm: false,
      graph: sampleGraph,
    });
  });
});

describe("parseDigestsMarker", () => {
  test("accepts flat digests object", async () => {
    await expect(parseDigestsMarker(sampleDigests)).resolves.toEqual(sampleDigests);
  });

  test("accepts manifest-shaped object", async () => {
    await expect(parseDigestsMarker({ digests: sampleDigests })).resolves.toEqual(sampleDigests);
  });

  test("returns null for graph-ref-only payload", async () => {
    await expect(parseDigestsMarker(sampleGraph)).resolves.toBeNull();
  });
});

describe("loadPreviousDigests", () => {
  test("returns null when local marker is absent in dry-run", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-prev-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    await mkdir(outDir, { recursive: true });
    const ctx = { ...baseCtx, outDir, dryRun: true };

    await expect(loadPreviousDigests(ctx)).resolves.toBeNull();

    await rm(root, { recursive: true, force: true });
  });

  test("reads local marker in dry-run", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-prev-hit-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    await mkdir(outDir, { recursive: true });
    const ctx = { ...baseCtx, outDir, dryRun: true };
    const marker = previousDigestsMarkerPath(ctx);
    await writeFile(marker, JSON.stringify(sampleDigests, null, 2));

    await expect(loadPreviousDigests(ctx)).resolves.toEqual(sampleDigests);

    await rm(root, { recursive: true, force: true });
  });

  test("reads manifest-shaped local marker", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-prev-manifest-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    await mkdir(outDir, { recursive: true });
    const ctx = { ...baseCtx, outDir, dryRun: true };
    await writeFile(
      previousDigestsMarkerPath(ctx),
      JSON.stringify({ digests: sampleDigests, skipLlm: true, graph: sampleGraph }, null, 2),
    );

    await expect(loadPreviousDigests(ctx)).resolves.toEqual(sampleDigests);

    await rm(root, { recursive: true, force: true });
  });

  test("round-trip via publishDigestsMarker enables skip on unchanged digests", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-prev-rt-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    await mkdir(outDir, { recursive: true });
    const ctx = { ...baseCtx, outDir, dryRun: true };

    const { publishDigestsMarker } = await import("./publish/r2-graph");
    await publishDigestsMarker(ctx, sampleDigests);
    const prev = await loadPreviousDigests(ctx);
    expect(shouldSkipLlm(sampleDigests, prev)).toBe(true);
    expect(shouldSkipLlm({ ...sampleDigests, sbomDigest: "sha256:other" }, prev)).toBe(false);

    await rm(root, { recursive: true, force: true });
  });
});

describe("runJob orchestration order", () => {
  // runJob itself can't be unit-tested end-to-end without cloning a real repo
  // and shelling out to repomix/gitnexus/syft, so this locks the contract at
  // the source level: publishDigestsMarker must mean "narrative + brain PR
  // succeeded", so it may only appear once, after publishBrainPr, and after
  // the phase-1/skip early-return guard (so phase "1" and the skip path never
  // reach it).
  test("publishDigestsMarker is called exactly once, after publishBrainPr and after the early-return guard", async () => {
    const src = await readFile(fileURLToPath(new URL("./index.ts", import.meta.url)), "utf8");

    const markerCalls = [...src.matchAll(/publishDigestsMarker\(ctx, digests\)/g)];
    expect(markerCalls).toHaveLength(1);
    const markerIdx = markerCalls[0]!.index!;

    const guardIdx = src.indexOf("if (!shouldRunLlmSection(ctx.phase, skipLlm))");
    const brainPrIdx = src.indexOf("await publishBrainPr(ctx)");
    expect(guardIdx).toBeGreaterThan(-1);
    expect(brainPrIdx).toBeGreaterThan(-1);

    // Unreachable from the phase-1 / skip-LLM early return, which happens
    // strictly before this point in the function body.
    expect(markerIdx).toBeGreaterThan(guardIdx);
    // Only runs once the brain PR publish step has completed.
    expect(markerIdx).toBeGreaterThan(brainPrIdx);
  });
});
