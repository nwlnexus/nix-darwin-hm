import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { JobContext } from "../types";
import { packOutPath, parsePackDigest } from "./pack";

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

describe("pack", () => {
  test("packOutPath resolves repomix.xml under outDir", () => {
    expect(packOutPath(baseCtx)).toBe(join("/tmp/out", "repomix.xml"));
  });

  test("parsePackDigest hashes file contents", async () => {
    const dir = await mkdtemp(join(tmpdir(), "pack-"));
    const p = join(dir, "repomix.xml");
    await writeFile(p, "<repo>test</repo>");
    const d = await parsePackDigest(p);
    expect(d.startsWith("sha256:")).toBe(true);
    expect(d).toBe(await parsePackDigest(p));
  });
});
