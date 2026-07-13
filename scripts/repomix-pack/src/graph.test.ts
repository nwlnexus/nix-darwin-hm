import { test, expect } from "bun:test";
import { refreshGraph } from "./graph";
import { readRegistry, type RegistryEntry } from "./registry";
import { RepoTarget } from "./types";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  chmodSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ---------------------------------------------------------------------------
// Fixtures.
//
// SAFETY: every test here points `registryPath` at a temp dir. Nothing in this
// file may read or write the real ~/.gitnexus/registry.json (which holds real,
// expensive entries), and nothing may write under ~/projects/**. The gitnexus
// binary is always a mock -- a real `analyze` takes 14s+ and hundreds of MB.
// ---------------------------------------------------------------------------

interface Fixture {
  root: string;
  cachePath: string;
  devClonePath: string;
  registryPath: string;
  logPath: string;
  headSha: string;
  target: RepoTarget;
}

function sh(cmd: string[], cwd: string): string {
  const res = Bun.spawnSync(cmd, { cwd });
  if (res.exitCode !== 0) {
    throw new Error(`${cmd.join(" ")} failed: ${res.stderr.toString()}`);
  }
  return res.stdout.toString().trim();
}

/** A real git repo standing in for the persistent cache checkout. */
function makeFixture(opts: { withDevClone?: boolean } = {}): Fixture {
  const root = mkdtempSync(join(tmpdir(), "graph-"));
  const cachePath = join(root, "cache", "acme", "widget");
  mkdirSync(cachePath, { recursive: true });

  // The cache checkout carries the target repo's own mise.toml -- the exact
  // condition that makes cwd-based invocation blow up in the real world.
  writeFileSync(join(cachePath, "mise.toml"), '[tools]\nnode = "22"\n');
  writeFileSync(join(cachePath, "a.ts"), "export const a = 1;\n");
  sh(["git", "init", "-q", "."], cachePath);
  sh(["git", "add", "-A"], cachePath);
  sh(
    [
      "git", "-c", "user.email=t@t", "-c", "user.name=t",
      "-c", "commit.gpgsign=false", "commit", "-qm", "init",
    ],
    cachePath,
  );
  const headSha = sh(["git", "rev-parse", "HEAD"], cachePath);

  const devClonePath = join(root, "dev", "widget");
  if (opts.withDevClone !== false) mkdirSync(devClonePath, { recursive: true });

  const target: RepoTarget = {
    owner: "acme",
    name: "widget",
    slug: "acme/widget",
    sshHost: "github.com",
    originUrl: "git@github.com:acme/widget.git",
    defaultBranch: "main",
    packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack",
    group: "personal",
    graph: true,
    devClonePath,
  };

  return {
    root,
    cachePath,
    devClonePath,
    registryPath: join(root, "gitnexus", "registry.json"),
    logPath: join(root, "invocation.json"),
    headSha,
    target,
  };
}

/**
 * A stand-in for the gitnexus binary.
 *
 * `success` mimics what a real `analyze` leaves behind: a storage dir with
 * meta.json + gitnexus.json (both carrying `repoPath`), and a registry entry
 * anchored at the path it was handed. It also records argv + cwd so tests can
 * assert we never invoke it from inside the checkout.
 */
function writeMockGitnexus(
  fx: Fixture,
  mode: "success" | "fail" | "hang",
  nodes = 5,
): string {
  const binPath = join(fx.root, "gitnexus-mock");
  const script = `#!/usr/bin/env bun
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
writeFileSync(
  ${JSON.stringify(fx.logPath)},
  JSON.stringify({ argv, cwd: process.cwd() }, null, 2),
);

const mode = ${JSON.stringify(mode)};
if (mode === "hang") {
  await new Promise(() => {});
}
if (mode === "fail") {
  process.stderr.write("ladybugdb: database is corrupt\\n");
  process.exit(1);
}

const repoPath = argv[argv.length - 1];
const nameIdx = argv.indexOf("--name");
const alias = argv[nameIdx + 1];
const storagePath = join(repoPath, ".gitnexus");
mkdirSync(storagePath, { recursive: true });

const meta = {
  repoPath,
  lastCommit: ${JSON.stringify(fx.headSha)},
  indexedAt: new Date().toISOString(),
  branch: "main",
  stats: { files: 2, nodes: ${nodes}, edges: 5, communities: 1, processes: 0, embeddings: 0 },
  schemaVersion: 5,
};
writeFileSync(join(storagePath, "meta.json"), JSON.stringify(meta, null, 2));
writeFileSync(join(storagePath, "gitnexus.json"), JSON.stringify(meta, null, 2));
// Stand in for the LadybugDB payload so the byte count is non-trivial.
writeFileSync(join(storagePath, "lbug"), "x".repeat(4096));

// Real gitnexus registers the repo at the path it analyzed, merging into any
// existing entry (which is why the user's multi-branch \`branches\` field
// survives a re-analyze in the real registry).
const { updateRegistry } = await import(${JSON.stringify(join(import.meta.dir, "registry.ts"))});
await updateRegistry(
  (entries) => {
    const fresh = {
      name: alias,
      path: repoPath,
      storagePath,
      lastCommit: ${JSON.stringify(fx.headSha)},
      indexedAt: meta.indexedAt,
      stats: meta.stats,
      branch: "main",
    };
    const idx = entries.findIndex((e) => e.name === alias);
    if (idx === -1) return [...entries, fresh];
    const next = [...entries];
    next[idx] = { ...next[idx], ...fresh };
    return next;
  },
  ${JSON.stringify(fx.registryPath)},
);
`;
  writeFileSync(binPath, script);
  chmodSync(binPath, 0o755);
  return binPath;
}

function seedRegistry(fx: Fixture, entries: RegistryEntry[]): void {
  mkdirSync(join(fx.root, "gitnexus"), { recursive: true });
  writeFileSync(fx.registryPath, JSON.stringify(entries, null, 2));
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

function invocation(fx: Fixture): { argv: string[]; cwd: string } | null {
  return existsSync(fx.logPath) ? readJson(fx.logPath) : null;
}

// ---------------------------------------------------------------------------
// Step 1: commit gate
// ---------------------------------------------------------------------------

test("commit gate HIT: registry lastCommit == cache HEAD -> skipped, analyze never runs", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: fx.headSha,
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("skipped");
  expect(invocation(fx)).toBeNull(); // the expensive part never ran
});

test("commit gate MISS: lastCommit differs from cache HEAD -> analyze runs", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: "0000000000000000000000000000000000000000",
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(invocation(fx)).not.toBeNull();
});

test("commit gate MISS: no registry entry at all -> analyze runs", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(invocation(fx)?.argv).toContain("analyze");
});

// ---------------------------------------------------------------------------
// Step 2: invocation shape + the mise-trust constraint
// ---------------------------------------------------------------------------

test("analyze is invoked with the documented flags and the checkout as a PATH ARG", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  const inv = invocation(fx)!;
  expect(inv.argv).toEqual([
    "analyze",
    "--no-stats",
    "--skip-skills",
    "--name",
    "widget",
    fx.cachePath,
  ]);
});

test("analyze is NEVER invoked with the cache checkout as cwd (mise trust blocker)", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  const inv = invocation(fx)!;
  // The checkout carries the target repo's own mise.toml; running there makes
  // the mise shim die with "Config files in ... are not trusted".
  expect(inv.cwd).not.toBe(fx.cachePath);
  expect(existsSync(join(inv.cwd, "mise.toml"))).toBe(false);
});

// ---------------------------------------------------------------------------
// Step 3: re-anchor
// ---------------------------------------------------------------------------

test("re-anchor rewrites ALL THREE locations: registry entry, meta.json, gitnexus.json", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success", 42);
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(result.nodes).toBe(42);
  expect(result.bytes).toBeGreaterThan(0);

  const storagePath = join(fx.cachePath, ".gitnexus");

  // 1. registry entry: path -> dev clone, storage stays in the cache.
  const entries = await readRegistry(fx.registryPath);
  const entry = entries.find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.devClonePath);
  expect(entry.storagePath).toBe(storagePath);

  // 2 + 3. both storage manifests point at the dev clone.
  expect(readJson(join(storagePath, "meta.json")).repoPath).toBe(fx.devClonePath);
  expect(readJson(join(storagePath, "gitnexus.json")).repoPath).toBe(fx.devClonePath);
});

test("re-anchor preserves fields gitnexus owns but we do not model (branch/branches)", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  // Simulate the user's multi-branch index landing in the entry.
  const branches = [
    { branch: "main", indexedAt: "2026-07-07T02:11:54.001Z", lastCommit: "abc1234", stats: {} },
  ];
  await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });
  const { updateRegistry } = await import("./registry");
  await updateRegistry(
    (es) => es.map((e) => (e.name === "widget" ? { ...e, branches } : e)),
    fx.registryPath,
  );

  // Re-run against a new commit so the gate misses and we re-anchor again.
  writeFileSync(join(fx.cachePath, "b.ts"), "export const b = 2;\n");
  sh(["git", "add", "-A"], fx.cachePath);
  sh(
    ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "two"],
    fx.cachePath,
  );

  await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  const entries = await readRegistry(fx.registryPath);
  const entry = entries.find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.devClonePath);
  expect(entry.branches).toEqual(branches);
});

test("dev clone missing on this machine -> re-anchor is SKIPPED, and that is not an error", async () => {
  const fx = makeFixture({ withDevClone: false });
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  // The graph is still built and queryable; only the working-tree tools are moot.
  expect(result.status).toBe("analyzed");
  expect(result.error).toBeUndefined();

  const storagePath = join(fx.cachePath, ".gitnexus");
  const entries = await readRegistry(fx.registryPath);
  const entry = entries.find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.cachePath); // left anchored at the cache
  expect(entry.storagePath).toBe(storagePath);
  expect(readJson(join(storagePath, "meta.json")).repoPath).toBe(fx.cachePath);
  expect(readJson(join(storagePath, "gitnexus.json")).repoPath).toBe(fx.cachePath);
});

// ---------------------------------------------------------------------------
// Step 4: failure handling
// ---------------------------------------------------------------------------

test("failed analyze DEREGISTERS the entry rather than leave a half-written graph", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  // gitnexus registers the repo before it finishes; a crash mid-analyze leaves
  // this entry pointing at a possibly-corrupt LadybugDB.
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.cachePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: "0000000",
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");
  expect(result.error).toBeTruthy();

  const entries = await readRegistry(fx.registryPath);
  expect(entries.find((e) => e.name === "widget")).toBeUndefined();
});

test("failed analyze leaves OTHER repos' entries untouched (per-repo isolation)", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  const bystander: RegistryEntry = {
    name: "olympus-sdk",
    path: "/Users/x/projects/personal/olympus-sdk",
    storagePath: "/Users/x/projects/personal/olympus-sdk/.gitnexus",
    lastCommit: "5bae710",
  };
  seedRegistry(fx, [
    bystander,
    { name: "widget", path: fx.cachePath, storagePath: join(fx.cachePath, ".gitnexus") },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");
  const entries = await readRegistry(fx.registryPath);
  expect(entries).toEqual([bystander]);
});

test("analyze timeout -> failed + deregistered, never throws into the sweep", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "hang");
  seedRegistry(fx, [
    { name: "widget", path: fx.cachePath, storagePath: join(fx.cachePath, ".gitnexus") },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
    timeoutMs: 300,
  });

  expect(result.status).toBe("failed");
  expect(result.error).toMatch(/timed out/i);

  const entries = await readRegistry(fx.registryPath);
  expect(entries.find((e) => e.name === "widget")).toBeUndefined();
});

test("a missing gitnexus binary is reported as failed, not thrown", async () => {
  const fx = makeFixture();
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: join(fx.root, "no-such-binary"),
  });

  expect(result.status).toBe("failed");
  expect(result.error).toBeTruthy();
});
