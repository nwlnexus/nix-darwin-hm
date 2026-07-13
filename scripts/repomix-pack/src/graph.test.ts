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
  statSync,
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
  mode: "success" | "fail" | "hang" | "empty-success" | "readonly-storage",
  nodes = 5,
): string {
  const binPath = join(fx.root, "gitnexus-mock");
  const script = `#!/usr/bin/env bun
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
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
if (mode !== "empty-success") mkdirSync(storagePath, { recursive: true });

const meta = {
  repoPath,
  lastCommit: ${JSON.stringify(fx.headSha)},
  indexedAt: new Date().toISOString(),
  branch: "main",
  stats: { files: 2, nodes: ${nodes}, edges: 5, communities: 1, processes: 0, embeddings: 0 },
  schemaVersion: 5,
};
if (mode !== "empty-success") {
  for (const f of ["meta.json", "gitnexus.json"]) {
    writeFileSync(join(storagePath, f), JSON.stringify(meta, null, 2));
    chmodSync(join(storagePath, f), 0o600); // real gitnexus writes these 0600
  }
  // Stand in for the LadybugDB payload so the byte count is non-trivial.
  writeFileSync(join(storagePath, "lbug"), "x".repeat(4096));
}

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

if (mode === "readonly-storage") {
  // Storage the process can no longer write into: the manifest rewrite will
  // blow up with EACCES partway through the re-anchor.
  chmodSync(storagePath, 0o500);
}
`;
  writeFileSync(binPath, script);
  chmodSync(binPath, 0o755);
  return binPath;
}

function seedRegistry(fx: Fixture, entries: RegistryEntry[]): void {
  mkdirSync(join(fx.root, "gitnexus"), { recursive: true });
  writeFileSync(fx.registryPath, JSON.stringify(entries, null, 2));
}

/**
 * Stand in for storage a PREVIOUS run left in the cache. A registry entry whose
 * lastCommit matches HEAD is only an honest gate hit if the storage it points
 * at is actually on disk.
 */
function seedStorage(fx: Fixture, repoPath: string, nodes = 5): string {
  const storagePath = join(fx.cachePath, ".gitnexus");
  mkdirSync(storagePath, { recursive: true });
  const meta = {
    repoPath,
    lastCommit: fx.headSha,
    branch: "main",
    stats: { files: 2, nodes, edges: 5 },
    schemaVersion: 5,
  };
  for (const f of ["meta.json", "gitnexus.json"]) {
    writeFileSync(join(storagePath, f), JSON.stringify(meta, null, 2), { mode: 0o600 });
    chmodSync(join(storagePath, f), 0o600);
  }
  writeFileSync(join(storagePath, "lbug"), "x".repeat(4096));
  return storagePath;
}

function modeOf(path: string): string {
  return (statSync(path).mode & 0o777).toString(8);
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
  // A gate hit is only honest if the storage a previous run built is still there.
  seedStorage(fx, fx.devClonePath);
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

// ---------------------------------------------------------------------------
// Step 4 (regression): a failure must never delete storage this run never opened
// ---------------------------------------------------------------------------

test("spawn failure PRESERVES a pre-existing entry pointing at OTHER storage", async () => {
  // The production failure mode: gitnexus is a mise shim and doesn't resolve on
  // PATH under launchd -> spawn throws ENOENT -> analyze never ran and touched
  // nothing. Deleting the entry here would orphan hundreds of MB of storage the
  // user's real graph depends on, with no backup.
  const fx = makeFixture();
  const healthy: RegistryEntry = {
    name: "widget", // same name we sweep -- this is the whole trap
    path: fx.devClonePath,
    storagePath: join(fx.root, "elsewhere", ".gitnexus"), // NOT our cache storage
    lastCommit: "0000000000000000000000000000000000000000",
    branch: "main",
    branches: [{ branch: "main", lastCommit: "abc", stats: {} }],
  };
  seedRegistry(fx, [healthy]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: join(fx.root, "no-such-binary"), // ENOENT on spawn
  });

  expect(result.status).toBe("failed");

  const entries = await readRegistry(fx.registryPath);
  expect(entries).toEqual([healthy]); // untouched, branches and all
});

test("failed analyze still deregisters when the entry points at OUR cache storage", async () => {
  // Same-storage case: this run really could have half-written that LadybugDB.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
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

  expect(result.status).toBe("failed");
  const entries = await readRegistry(fx.registryPath);
  expect(entries.find((e) => e.name === "widget")).toBeUndefined();
});

// ---------------------------------------------------------------------------
// Step 1 (regression): the gate skips the ANALYZE, not the RE-ANCHOR
// ---------------------------------------------------------------------------

test("gate HIT with the entry stranded at the cache -> re-anchored anyway (rename safety)", async () => {
  // Run 1 happened with no dev clone on this machine, so the entry is anchored
  // at the cache. The user has since cloned the repo. HEAD hasn't moved, so a
  // gate that skipped everything would leave path=<cache> forever -- and
  // gitnexus's `rename` would write the user's refactor into the cache
  // checkout, where checkout()'s `reset --hard` silently destroys it.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  const storagePath = seedStorage(fx, fx.cachePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.cachePath, // stranded
      storagePath,
      lastCommit: fx.headSha,
      branches: [{ branch: "main", lastCommit: fx.headSha, stats: {} }],
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("skipped");
  expect(invocation(fx)).toBeNull(); // the expensive part still never ran

  const entry = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.devClonePath); // re-anchored
  expect(entry.storagePath).toBe(storagePath); // storage stays in the cache
  expect(entry.branches).toHaveLength(1); // fields we don't model survive
  expect(readJson(join(storagePath, "meta.json")).repoPath).toBe(fx.devClonePath);
  expect(readJson(join(storagePath, "gitnexus.json")).repoPath).toBe(fx.devClonePath);
});

test("gate HIT but the cache storage was pruned -> treated as a MISS, re-analyzes", async () => {
  // User cleared ~/.cache/repomix-pipeline to reclaim space. The entry survives
  // with a matching lastCommit, so a naive gate hits forever while storagePath
  // points at a deleted dir: the graph is dead and never rebuilds.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: join(fx.cachePath, ".gitnexus"), // nothing on disk there
      lastCommit: fx.headSha,
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(invocation(fx)).not.toBeNull();
  expect(existsSync(join(fx.cachePath, ".gitnexus", "meta.json"))).toBe(true);
});

test("commit gate compares SHAs by plain equality (a short SHA is a MISS, not a skip)", async () => {
  // A false skip silently serves a stale graph; a false miss costs one
  // re-analyze. Never trade the cheap failure for the silent one.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: fx.headSha.slice(0, 7),
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(invocation(fx)).not.toBeNull();
});

// ---------------------------------------------------------------------------
// Step 3 (regression): write order, post-condition, permissions, storagePath
// ---------------------------------------------------------------------------

test("a manifest write failure leaves the entry fully CACHE-anchored, never half-anchored", async () => {
  // The registry is the single commit point: manifests are written first, so a
  // throw mid-re-anchor can never leave registry=devClone / meta=cache.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "readonly-storage");
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  const storagePath = join(fx.cachePath, ".gitnexus");
  chmodSync(storagePath, 0o700); // so the temp dir can be cleaned up

  expect(result.status).toBe("failed");

  const entry = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.cachePath); // coherent: cache-anchored, like a missing dev clone
  expect(readJson(join(storagePath, "meta.json")).repoPath).toBe(fx.cachePath);
});

test("analyze exits 0 but writes no meta.json -> hard failure, not a silent no-op", async () => {
  // rewriteRepoPath tolerates missing manifests, so without a post-condition we
  // would report a built graph that isn't there.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "empty-success");
  seedRegistry(fx, []);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");
  expect(result.error).toMatch(/meta\.json/);
});

test("re-anchor preserves manifest permissions (0600, not widened to 0644)", async () => {
  // meta.json/gitnexus.json carry fileHashes and full path listings.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedRegistry(fx, []);

  await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  const storagePath = join(fx.cachePath, ".gitnexus");
  expect(modeOf(join(storagePath, "meta.json"))).toBe("600");
  expect(modeOf(join(storagePath, "gitnexus.json"))).toBe("600");
});

test("re-anchor changes only `path` -- it never asserts its own storagePath", async () => {
  // storagePath is gitnexus's field: post-analyze it already IS the cache, so
  // writing our assumption over it can only ever be wrong.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedStorage(fx, fx.cachePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.cachePath,
      storagePath: "/custom/store", // gitnexus's value, whatever it is
      lastCommit: fx.headSha,
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("skipped");
  const after = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(after.path).toBe(fx.devClonePath); // re-anchored
  expect(after.storagePath).toBe("/custom/store"); // preserved, not asserted
});

// ---------------------------------------------------------------------------
// target.graph opt-out
// ---------------------------------------------------------------------------

test("target.graph === false -> skipped: no analyze, and the registry is never touched", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  const entry: RegistryEntry = {
    name: "widget",
    path: fx.devClonePath,
    storagePath: join(fx.cachePath, ".gitnexus"),
    lastCommit: "0000000000000000000000000000000000000000",
  };
  seedRegistry(fx, [entry]);

  const result = await refreshGraph(
    { ...fx.target, graph: false },
    fx.cachePath,
    { registryPath: fx.registryPath, gitnexusBin: bin },
  );

  expect(result.status).toBe("skipped");
  expect(invocation(fx)).toBeNull();
  expect(await readRegistry(fx.registryPath)).toEqual([entry]);
});
