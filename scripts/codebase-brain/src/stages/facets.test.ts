import { describe, expect, test } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { JobContext } from "../types";
import { buildFacetsPayload, facetsOutPath, runFacetsStage } from "./facets";

const baseCtx: JobContext = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123",
  workDir: "/tmp/work",
  outDir: "/tmp/out",
  packPath: ".llm/repomix.xml",
  configPath: "/tmp/repomix.config.json",
  brainRepo: "second-brain",
  brainContentRoot: "docs/codebases",
  r2Bucket: "nwl-codebase-brain",
  r2Prefix: "graphs",
  dryRun: false,
  phase: "all",
};

describe("facets", () => {
  test("facetsOutPath resolves facet.json under outDir", () => {
    expect(facetsOutPath(baseCtx)).toBe(join("/tmp/out", "facet.json"));
  });

  test("buildFacetsPayload includes repo metadata and graphDir", () => {
    const graphDir = "/tmp/work/.gitnexus";
    expect(buildFacetsPayload(baseCtx, graphDir)).toEqual({
      repo: "moneta",
      owner: "nwlnexus",
      sha: "abc123",
      graphDir,
      note: "v1 facets are thin; cluster supplements optional later",
    });
  });

  test("runFacetsStage writes facet.json", async () => {
    const outDir = await mkdtemp(join(tmpdir(), "facets-"));
    const ctx = { ...baseCtx, outDir };
    const graphDir = join(ctx.workDir, ".gitnexus");
    const out = await runFacetsStage(ctx, graphDir);
    expect(out).toBe(join(outDir, "facet.json"));
    const payload = await Bun.file(out).json();
    expect(payload.repo).toBe("moneta");
    expect(payload.graphDir).toBe(graphDir);
  });
});
