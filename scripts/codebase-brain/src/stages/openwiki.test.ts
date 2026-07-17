import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { JobContext } from "../types";
import {
  buildOpenWikiEnv,
  copyPublishableWikiPages,
  srcWikiPath,
  wikiDirPath,
} from "./openwiki";

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

const savedEnv = { ...process.env };

afterEach(() => {
  process.env = { ...savedEnv };
});

describe("openwiki paths", () => {
  test("wikiDirPath resolves openwiki-okf under outDir", () => {
    expect(wikiDirPath(baseCtx)).toBe(join("/tmp/out", "openwiki-okf"));
  });

  test("srcWikiPath resolves openwiki under workDir", () => {
    expect(srcWikiPath("/tmp/work")).toBe(join("/tmp/work", "openwiki"));
  });
});

describe("buildOpenWikiEnv", () => {
  test("throws when no Anthropic key is available", () => {
    delete process.env.ANTHROPIC_API_KEY;
    expect(() => buildOpenWikiEnv({ ...baseCtx })).toThrow(
      "ANTHROPIC_API_KEY required for openwiki narrative",
    );
  });

  test("prefers ctx.anthropicApiKey over process.env", () => {
    process.env.ANTHROPIC_API_KEY = "env-key";
    const env = buildOpenWikiEnv({ ...baseCtx, anthropicApiKey: "ctx-key" });
    expect(env.ANTHROPIC_API_KEY).toBe("ctx-key");
    expect(env.OPENWIKI_PROVIDER).toBe("anthropic");
    expect(env.OPENWIKI_OKF).toBe("1");
  });

  test("falls back to process.env.ANTHROPIC_API_KEY", () => {
    process.env.ANTHROPIC_API_KEY = "env-key";
    const env = buildOpenWikiEnv({ ...baseCtx });
    expect(env.ANTHROPIC_API_KEY).toBe("env-key");
  });

  test("includes OPENWIKI_MODEL_ID when set in process.env", () => {
    process.env.ANTHROPIC_API_KEY = "env-key";
    process.env.OPENWIKI_MODEL_ID = "claude-sonnet-4-5";
    const env = buildOpenWikiEnv({ ...baseCtx });
    expect(env.OPENWIKI_MODEL_ID).toBe("claude-sonnet-4-5");
  });

  test("omits OPENWIKI_MODEL_ID when unset", () => {
    process.env.ANTHROPIC_API_KEY = "env-key";
    delete process.env.OPENWIKI_MODEL_ID;
    const env = buildOpenWikiEnv({ ...baseCtx });
    expect(env.OPENWIKI_MODEL_ID).toBeUndefined();
  });
});

describe("copyPublishableWikiPages", () => {
  test("copies only publishable markdown and returns relative paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "openwiki-src-"));
    const dest = await mkdtemp(join(tmpdir(), "openwiki-dest-"));

    await mkdir(join(root, "services", "api"), { recursive: true });
    await mkdir(join(root, ".github", "workflows"), { recursive: true });

    await writeFile(join(root, "Architecture.md"), "# Architecture");
    await writeFile(join(root, "services", "api", "overview.md"), "# API");
    await writeFile(join(root, "AGENTS.md"), "# side effect");
    await writeFile(join(root, "CLAUDE.md"), "# side effect");
    await writeFile(join(root, ".github", "workflows", "openwiki-update.yml"), "on: push");
    await writeFile(join(root, "package.json"), "{}");

    const copied = await copyPublishableWikiPages(root, dest);

    expect(copied.sort()).toEqual(["Architecture.md", "services/api/overview.md"].sort());
    expect(await readFile(join(dest, "Architecture.md"), "utf8")).toBe("# Architecture");
    expect(await readFile(join(dest, "services", "api", "overview.md"), "utf8")).toBe("# API");
    expect(await Bun.file(join(dest, "AGENTS.md")).exists()).toBe(false);
    expect(await Bun.file(join(dest, "package.json")).exists()).toBe(false);
  });

  test("returns empty list when source wiki dir is missing", async () => {
    const dest = await mkdtemp(join(tmpdir(), "openwiki-dest-"));
    expect(await copyPublishableWikiPages("/nonexistent/openwiki", dest)).toEqual([]);
  });
});
