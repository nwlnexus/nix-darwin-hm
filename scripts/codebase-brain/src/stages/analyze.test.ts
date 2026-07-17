import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { JobContext } from "../types";
import { graphDirPath, graphTarballPath, parseGraphDigest } from "./analyze";

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

describe("analyze", () => {
  test("graphDirPath resolves .gitnexus under workDir", () => {
    expect(graphDirPath("/tmp/work")).toBe(join("/tmp/work", ".gitnexus"));
  });

  test("graphTarballPath embeds sha in filename", () => {
    expect(graphTarballPath(baseCtx)).toBe(join("/tmp/out", "graph-abc123.tgz"));
  });

  test("parseGraphDigest hashes tarball bytes", async () => {
    const dir = await mkdtemp(join(tmpdir(), "graph-"));
    const p = join(dir, "graph.tgz");
    await writeFile(p, "fake-tarball-bytes");
    const d = await parseGraphDigest(p);
    expect(d.startsWith("sha256:")).toBe(true);
  });
});
