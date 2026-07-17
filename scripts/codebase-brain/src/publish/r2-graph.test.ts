import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TEMPLATE_VERSION, shouldSkipLlm } from "../digests";
import type { JobContext } from "../types";
import {
  buildGraphRef,
  graphRefOutPath,
  latestDigestsObjectKey,
  localDigestsMarkerPath,
  publishDigestsMarker,
  publishGraph,
  readLocalDigestsMarker,
} from "./r2-graph";
import { loadPreviousDigests } from "../index";

const INTENT =
  "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later";

const baseCtx: JobContext = {
  owner: "nwlnexus",
  repo: "moneta",
  sha: "abc123def456",
  workDir: "/tmp/work",
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

const sampleDigests = {
  packHash: "sha256:pack",
  graphDigest: "sha256:graph",
  sbomDigest: "sha256:sbom",
  templateVersion: TEMPLATE_VERSION,
};

describe("buildGraphRef", () => {
  test("derives r2 key and uri from ctx", () => {
    const digest = "sha256:deadbeef";
    const ref = buildGraphRef(baseCtx, digest);
    const key = `graphs/nwlnexus/moneta/${baseCtx.sha}.tgz`;
    expect(ref.r2Uri).toBe(`r2://nwl-codebase-brain/${key}`);
    expect(ref.latestUri).toBe("r2://nwl-codebase-brain/graphs/nwlnexus/moneta/latest");
  });

  test("passthrough owner, repo, sha, graphDigest", () => {
    const digest = "sha256:cafebabe";
    const ref = buildGraphRef(baseCtx, digest);
    expect(ref.owner).toBe("nwlnexus");
    expect(ref.repo).toBe("moneta");
    expect(ref.sha).toBe("abc123def456");
    expect(ref.graphDigest).toBe(digest);
  });

  test("intent is exact contract C string", () => {
    const ref = buildGraphRef(baseCtx, "sha256:x");
    expect(ref.intent).toBe(INTENT);
  });
});

describe("publishGraph", () => {
  test("dryRun writes graph-ref.json and skips upload", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-r2-"));
    const outDir = join(root, "out");
    const tarballPath = join(root, "graph.tgz");
    await writeFile(tarballPath, "fake-tarball-bytes");
    const ctx = { ...baseCtx, outDir, dryRun: true };
    const digest = "sha256:test123";

    const ref = await publishGraph(ctx, tarballPath, digest);

    const written = JSON.parse(await readFile(graphRefOutPath(ctx), "utf8"));
    expect(written).toEqual(ref);
    expect(ref.graphDigest).toBe(digest);
    expect(ref.intent).toBe(INTENT);

    await rm(root, { recursive: true, force: true });
  });

  test("missing R2 creds writes graph-ref.json without upload", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-r2-nocreds-"));
    const outDir = join(root, "out");
    const tarballPath = join(root, "graph.tgz");
    await writeFile(tarballPath, "fake-tarball-bytes");
    const ctx = { ...baseCtx, outDir, dryRun: false };
    const digest = "sha256:nocreds";

    const saved = {
      endpoint: process.env.AWS_ENDPOINT_URL,
      accessKey: process.env.AWS_ACCESS_KEY_ID,
      secretKey: process.env.AWS_SECRET_ACCESS_KEY,
    };
    delete process.env.AWS_ENDPOINT_URL;
    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;

    try {
      const ref = await publishGraph(ctx, tarballPath, digest);
      const written = JSON.parse(await readFile(graphRefOutPath(ctx), "utf8"));
      expect(written.r2Uri).toBe(ref.r2Uri);
      expect(written.graphDigest).toBe(digest);
    } finally {
      if (saved.endpoint !== undefined) process.env.AWS_ENDPOINT_URL = saved.endpoint;
      else delete process.env.AWS_ENDPOINT_URL;
      if (saved.accessKey !== undefined) process.env.AWS_ACCESS_KEY_ID = saved.accessKey;
      else delete process.env.AWS_ACCESS_KEY_ID;
      if (saved.secretKey !== undefined) process.env.AWS_SECRET_ACCESS_KEY = saved.secretKey;
      else delete process.env.AWS_SECRET_ACCESS_KEY;
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("publishDigestsMarker", () => {
  test("dry-run writes local marker with exact Digests JSON and skips upload", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-digests-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    const ctx = { ...baseCtx, outDir, dryRun: true };

    const saved = {
      endpoint: process.env.AWS_ENDPOINT_URL,
      accessKey: process.env.AWS_ACCESS_KEY_ID,
      secretKey: process.env.AWS_SECRET_ACCESS_KEY,
    };
    delete process.env.AWS_ENDPOINT_URL;
    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;

    try {
      const { localPath, r2Key } = await publishDigestsMarker(ctx, sampleDigests);

      expect(localPath).toBe(localDigestsMarkerPath(ctx));
      expect(r2Key).toBe(latestDigestsObjectKey(ctx));
      expect(r2Key).toBe("graphs/nwlnexus/moneta/latest-digests.json");
      expect(JSON.parse(await readFile(localPath, "utf8"))).toEqual(sampleDigests);
    } finally {
      if (saved.endpoint !== undefined) process.env.AWS_ENDPOINT_URL = saved.endpoint;
      else delete process.env.AWS_ENDPOINT_URL;
      if (saved.accessKey !== undefined) process.env.AWS_ACCESS_KEY_ID = saved.accessKey;
      else delete process.env.AWS_ACCESS_KEY_ID;
      if (saved.secretKey !== undefined) process.env.AWS_SECRET_ACCESS_KEY = saved.secretKey;
      else delete process.env.AWS_SECRET_ACCESS_KEY;
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("digests marker round-trip", () => {
  test("dry-run write then loadPreviousDigests enables shouldSkipLlm", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-digests-rt-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "abc123");
    const ctx = { ...baseCtx, outDir, dryRun: true };

    await publishDigestsMarker(ctx, sampleDigests);
    const prev = await loadPreviousDigests(ctx);
    expect(prev).toEqual(sampleDigests);
    expect(shouldSkipLlm(sampleDigests, prev)).toBe(true);

    const changed = { ...sampleDigests, packHash: "sha256:changed" };
    expect(shouldSkipLlm(changed, prev)).toBe(false);

    await rm(root, { recursive: true, force: true });
  });

  test("readLocalDigestsMarker reads marker written by publishDigestsMarker", async () => {
    const root = await mkdtemp(join(tmpdir(), "cb-digests-local-"));
    const outDir = join(root, "out", "nwlnexus", "moneta", "sha456");
    const ctx = { ...baseCtx, outDir, dryRun: true };

    await publishDigestsMarker(ctx, sampleDigests);
    await expect(readLocalDigestsMarker(ctx)).resolves.toEqual(sampleDigests);

    await rm(root, { recursive: true, force: true });
  });
});
