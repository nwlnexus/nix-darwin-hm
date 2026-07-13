import { test, expect } from "bun:test";
import { refreshGraph, defaultGitnexusBin } from "./graph";
import { readRegistry, type RegistryEntry } from "./registry";
import { RepoTarget } from "./types";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  existsSync,
  chmodSync,
  statSync,
} from "node:fs";
import { isAbsolute, join } from "node:path";
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
  /** Stands in for ~/.cache/repomix-pipeline: the ONLY deletable tree. */
  cacheRoot: string;
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
  const cacheRoot = join(root, "cache");
  const cachePath = join(cacheRoot, "acme", "widget");
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
    cacheRoot,
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
 * anchored at the path it was handed. It also records argv + cwd + the registry
 * AS SEEN AT INVOCATION, so tests can assert we never invoke it from inside the
 * checkout and that the alias was freed BEFORE analyze rather than after.
 *
 * It reproduces two refusals of the real binary (both verified by hand against
 * gitnexus 1.6.9 in a sandboxed HOME), because both of them are load-bearing:
 *
 *  1. Registry name collision. If an entry with our alias exists whose `path`
 *     is NOT the path being analyzed, it exits 1 without doing any work. The
 *     check keys on `path`, NOT on `storagePath`.
 *  2. Unregistered on-disk index. If the checkout already carries a `.gitnexus`
 *     that no registry entry claims (what an aborted analyze leaves behind), it
 *     exits 1 with "the on-disk index is incomplete and was not registered".
 */
function writeMockGitnexus(
  fx: Fixture,
  mode: "success" | "fail" | "hang" | "empty-success" | "readonly-storage",
  nodes = 5,
): string {
  const binPath = join(fx.root, "gitnexus-mock");
  const script = `#!/usr/bin/env bun
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const registryPath = ${JSON.stringify(fx.registryPath)};
const readRegistrySync = () => {
  try {
    return JSON.parse(readFileSync(registryPath, "utf8"));
  } catch {
    return [];
  }
};

const repoPath = argv[argv.length - 1];
const nameIdx = argv.indexOf("--name");
const alias = argv[nameIdx + 1];
const storagePath = join(repoPath, ".gitnexus");
const registryAtInvoke = readRegistrySync();

writeFileSync(
  ${JSON.stringify(fx.logPath)},
  JSON.stringify({ argv, cwd: process.cwd(), registryAtInvoke }, null, 2),
);

// (1) Registry name collision -- refused BEFORE any work happens.
const clash = registryAtInvoke.find((e) => e.name === alias && e.path !== repoPath);
if (clash) {
  process.stderr.write(
    \`Registry name collision:\\n  "\${alias}" is already used by "\${clash.path}".\\n\`,
  );
  process.exit(1);
}

// (2) An on-disk index nobody registered: the wedge an aborted analyze leaves.
const claimed = registryAtInvoke.some((e) => e.path === repoPath);
if (existsSync(storagePath) && !claimed) {
  process.stderr.write(
    \`Analysis did not finalize for \${repoPath}: the on-disk index is incomplete and was not registered. Inspect \${storagePath} - a leftover lbug.wal indicates an aborted write.\\n\`,
  );
  process.exit(1);
}

const mode = ${JSON.stringify(mode)};
if (mode === "hang") {
  await new Promise(() => {});
}
if (mode === "fail") {
  process.stderr.write("ladybugdb: database is corrupt\\n");
  process.exit(1);
}

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
// existing entry -- which is why the user's multi-branch \`branches\` field
// survives a RECALL (the entry is still there to merge into) but NOT an ADOPT
// (the entry was dropped, so this writes a fresh one and \`branches\` are gone).
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

function invocation(
  fx: Fixture,
): { argv: string[]; cwd: string; registryAtInvoke: RegistryEntry[] } | null {
  return existsSync(fx.logPath) ? readJson(fx.logPath) : null;
}

/**
 * The dev clone's OWN gitnexus index -- the storage all three of the user's
 * real entries point at. The runner must never write to or delete a byte of it:
 * it lives under ~/projects/** and there is no backup.
 */
function seedDevCloneStorage(fx: Fixture): string {
  const storagePath = join(fx.devClonePath, ".gitnexus");
  mkdirSync(storagePath, { recursive: true });
  writeFileSync(join(storagePath, "meta.json"), JSON.stringify({ repoPath: fx.devClonePath }));
  writeFileSync(join(storagePath, "lbug"), "PRECIOUS-DEV-CLONE-INDEX");
  return storagePath;
}

/** Every file under `dir`, as [relpath, contents]. Used to prove non-writes. */
function snapshotTree(dir: string): [string, string][] {
  const out: [string, string][] = [];
  const walk = (cur: string) => {
    for (const e of readdirSync(cur, { withFileTypes: true }).sort((a, b) =>
      a.name.localeCompare(b.name),
    )) {
      const p = join(cur, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) out.push([p.slice(dir.length), readFileSync(p, "utf8")]);
    }
  };
  walk(dir);
  return out;
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
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
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  const storagePath = join(fx.cachePath, ".gitnexus");
  expect(modeOf(join(storagePath, "meta.json"))).toBe("600");
  expect(modeOf(join(storagePath, "gitnexus.json"))).toBe("600");
});

test("re-anchor changes only `path` -- every other field gitnexus owns survives", async () => {
  // storagePath/branch/branches/stats are gitnexus's fields. reanchor spreads
  // the entry and touches `path` alone, so none of them may be clobbered.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedStorage(fx, fx.cachePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.cachePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: fx.headSha,
      branch: "main",
      branches: [{ name: "release/v2", storagePath: "/wherever/release-v2" }],
      stats: { nodes: 41 },
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("skipped"); // gate hit: ours, and HEAD hasn't moved
  const after = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(after.path).toBe(fx.devClonePath); // re-anchored...
  expect(after.storagePath).toBe(join(fx.cachePath, ".gitnexus")); // ...and nothing else moved
  expect(after.branch).toBe("main");
  expect(after.branches).toEqual([{ name: "release/v2", storagePath: "/wherever/release-v2" }]);
  expect(after.stats).toEqual({ nodes: 41 });
});

test("commit gate MISS: the entry is NOT ours, even at the same commit -> analyze + adopt", async () => {
  // The dangerous shape, and the reason the gate checks STORAGE OWNERSHIP and
  // not just the SHA: the user's own entry for this repo points at the index in
  // their dev clone, and its lastCommit tracks the same upstream HEAD as ours
  // does -- so it matches routinely, not exceptionally. On a SHA-only gate we
  // would "skip" every sweep, re-anchor storage we never built, and never build
  // a graph in the cache at all: a repo that looks permanently up to date and
  // has no graph. Not-ours must fall through to the ADOPT path.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  const foreignStorage = join(fx.devClonePath, ".gitnexus");
  mkdirSync(foreignStorage, { recursive: true });
  writeFileSync(join(foreignStorage, "lbug"), "x".repeat(2048));
  seedStorage(fx, fx.cachePath); // meta.json present, so ONLY ownership can gate
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: foreignStorage, // NOT ours
      lastCommit: fx.headSha, // ...and the SHA matches exactly
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(result.adopted?.orphanedStorage).toBe(foreignStorage); // ...and it is disclosed
  const after = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(after.storagePath).toBe(join(fx.cachePath, ".gitnexus")); // the graph is OURS now
  expect(after.path).toBe(fx.devClonePath);
  expect(existsSync(join(foreignStorage, "lbug"))).toBe(true); // never deleted under ~/projects
});

test("a missing gitnexus binary FAILS LOUDLY -- it never silently skips", async () => {
  // The launchd bug: a bare `gitnexus` resolves in an interactive shell and is
  // ENOENT under launchd, so every scheduled graph failed while the sweep
  // reported success. An absolute path that isn't there must be a FAILURE, and
  // it must beat the commit gate -- a gate hit would report "skipped" and hide
  // the breakage on exactly the repos that are up to date, i.e. most of them.
  const fx = makeFixture();
  seedStorage(fx, fx.cachePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.cachePath,
      storagePath: join(fx.cachePath, ".gitnexus"),
      lastCommit: fx.headSha, // the gate would otherwise HIT
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: join(fx.root, "nowhere", "gitnexus"),
  });

  expect(result.status).toBe("failed");
  expect(result.error).toMatch(/not found/i);
  expect(result.error).toContain(join(fx.root, "nowhere", "gitnexus"));
});

test("the default binary is an absolute mise SHIM path, never a bare name", async () => {
  // Bare `gitnexus` only resolves via ~/.local/share/mise/shims, which the
  // INTERACTIVE shell profile puts on PATH -- launchd never does. And the mise
  // INSTALLS path is a `#!/usr/bin/env node` script whose node is itself a mise
  // global, so it dies under a bare environment too. The shim (the mise binary)
  // is the only thing that resolves everywhere.
  const bin = defaultGitnexusBin("/home/x");
  expect(bin).toBe("/home/x/.local/share/mise/shims/gitnexus");
  expect(isAbsolute(bin)).toBe(true);
  expect(bin).not.toContain("/installs/");
});

// ---------------------------------------------------------------------------
// target.graph opt-out
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Registry name collision: adopting an alias already registered to the dev clone
//
// This is the state ALL THREE of the user's real entries are in (marquee,
// drop-app, olympus-sdk are each registered against their DEV CLONE). gitnexus
// refuses -- exit 1, "Registry name collision" -- to analyze under an alias
// whose entry points at a different path, so without adoption the graph would
// NEVER build for exactly the repos this phase exists to serve.
// ---------------------------------------------------------------------------

/** The pre-existing entry: our alias, anchored at the dev clone, with the dev
 *  clone's OWN storage -- i.e. storage that is not ours to touch. */
function collidingEntry(fx: Fixture): RegistryEntry {
  return {
    name: "widget",
    path: fx.devClonePath,
    storagePath: join(fx.devClonePath, ".gitnexus"), // NOT our cache storage
    lastCommit: "0000000000000000000000000000000000000000",
    branch: "main",
    branches: [{ branch: "main", lastCommit: "abc", stats: {} }],
  };
}

test("colliding alias is ADOPTED: the entry is dropped BEFORE analyze, and analyze then succeeds", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedDevCloneStorage(fx);
  seedRegistry(fx, [collidingEntry(fx)]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");

  // The alias was free by the time gitnexus ran -- otherwise it would have
  // refused. This is the assertion that fails without the fix.
  const inv = invocation(fx)!;
  expect(inv.registryAtInvoke.find((e) => e.name === "widget")).toBeUndefined();

  // And the end state is the one the design wants.
  const entry = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.devClonePath);
  expect(entry.storagePath).toBe(join(fx.cachePath, ".gitnexus"));
});

test("ADOPTION is registry-only: the dev clone's own index is never written or deleted", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedDevCloneStorage(fx);
  seedRegistry(fx, [collidingEntry(fx)]);

  const before = snapshotTree(fx.devClonePath);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  // Not one byte under the dev clone changed: its .gitnexus is orphaned in the
  // registry, never removed from disk. `gitnexus remove`/`clean` would have
  // deleted it -- which is exactly why we do not call them.
  expect(snapshotTree(fx.devClonePath)).toEqual(before);
  expect(readFileSync(join(fx.devClonePath, ".gitnexus", "lbug"), "utf8")).toBe(
    "PRECIOUS-DEV-CLONE-INDEX",
  );
});

test("ADOPTION that then FAILS restores the original entry byte-for-byte (branch/branches intact)", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  seedDevCloneStorage(fx);
  const original = collidingEntry(fx);
  seedRegistry(fx, [original]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");

  // It really was dropped first (otherwise this proves nothing)...
  expect(invocation(fx)!.registryAtInvoke.find((e) => e.name === "widget")).toBeUndefined();
  // ...and a failed adoption is a no-op on the registry.
  expect(await readRegistry(fx.registryPath)).toEqual([original]);
  // The dev clone's index survives a failed adoption too.
  expect(readFileSync(join(fx.devClonePath, ".gitnexus", "lbug"), "utf8")).toBe(
    "PRECIOUS-DEV-CLONE-INDEX",
  );
});

// ---------------------------------------------------------------------------
// Self-healing: one aborted analyze must not wedge the graph forever
//
// gitnexus refuses to analyze a checkout that already carries a `.gitnexus` no
// registry entry claims ("the on-disk index is incomplete and was not
// registered" / a leftover lbug.wal). An aborted analyze leaves exactly that,
// so every LATER sweep would fail the same way: a self-perpetuating failure.
// ---------------------------------------------------------------------------

test("a failed analyze REMOVES the cache storage it may have corrupted (self-heal)", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  const devStorage = seedDevCloneStorage(fx);
  seedStorage(fx, fx.cachePath); // storage a previous run left in the cache
  seedRegistry(fx, [
    { name: "widget", path: fx.cachePath, storagePath: join(fx.cachePath, ".gitnexus") },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");
  // Cache storage is gone, so the NEXT sweep starts clean instead of failing
  // forever on a leftover index.
  expect(existsSync(join(fx.cachePath, ".gitnexus"))).toBe(false);
  // ...and the self-heal is cache-only. It never reaches under ~/projects/**.
  expect(existsSync(devStorage)).toBe(true);
  expect(readFileSync(join(devStorage, "lbug"), "utf8")).toBe("PRECIOUS-DEV-CLONE-INDEX");
});

test("a leftover UNREGISTERED index in the cache heals in the SAME sweep, not the next one", async () => {
  // What an interrupted analyze (SIGKILL, laptop lid, launchd timeout) leaves:
  // storage on disk that no registry entry claims. gitnexus refuses to analyze
  // over it, so this repo's graph would be wedged permanently.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedStorage(fx, fx.cachePath);
  seedRegistry(fx, []); // nothing vouches for that storage

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(existsSync(join(fx.cachePath, ".gitnexus", "meta.json"))).toBe(true);
});

// ---------------------------------------------------------------------------
// Steady state: the entry we re-anchored at the dev clone must stay refreshable
// ---------------------------------------------------------------------------

test("steady state: an entry anchored at the dev clone is RECALLED, so re-analyze never collides", async () => {
  // After run 1 the entry is path=<devClone>, storagePath=<cache>/.gitnexus.
  // gitnexus keys its collision check on `path`, so a naive second run would be
  // refused -- the graph would build exactly once and then go stale forever.
  // The entry is OURS (its storage is the cache), so we recall it to the cache
  // for the analyze rather than dropping it, which keeps the index incremental
  // and lets gitnexus's own merge preserve the fields it owns.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  const branches = [{ branch: "main", lastCommit: "abc", stats: {} }];
  seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath, // re-anchored by a previous run
      storagePath: join(fx.cachePath, ".gitnexus"), // ...but the storage is ours
      lastCommit: "0000000000000000000000000000000000000000", // HEAD has moved
      branch: "main",
      branches,
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");

  // Recalled, not dropped: gitnexus saw an entry it could merge into.
  const seen = invocation(fx)!.registryAtInvoke.find((e) => e.name === "widget")!;
  expect(seen.path).toBe(fx.cachePath);
  expect(seen.branches).toEqual(branches);

  const entry = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(entry.path).toBe(fx.devClonePath); // re-anchored again
  expect(entry.storagePath).toBe(join(fx.cachePath, ".gitnexus"));
  expect(entry.lastCommit).toBe(fx.headSha);
  expect(entry.branches).toEqual(branches); // survived the round trip
});

// ---------------------------------------------------------------------------
// Adoption is LOSSY, and the loss must be VISIBLE
//
// On the ADOPT path the old entry is dropped and gitnexus creates a fresh one,
// so `branches` (multi-branch index registrations) are destroyed on the SUCCESS
// path -- permanently. olympus-sdk is exactly this case: the one real entry
// carrying `branches`, anchored at its dev clone. Carrying them forward would be
// WORSE (they describe branch storage under the OLD storagePath; the cache's
// `branches/` is empty, so gitnexus would believe in indexes that don't exist).
// Dropping them is the only coherent option -- so the sweep must SAY it did.
// ---------------------------------------------------------------------------

test("ADOPT reports what the drop cost: droppedBranches + the orphaned storage path", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  const devStorage = seedDevCloneStorage(fx);
  const original: RegistryEntry = {
    ...collidingEntry(fx),
    branches: [
      { branch: "main", lastCommit: "abc", stats: {} },
      { branch: "release/2.x", lastCommit: "def", stats: {} },
    ],
  };
  seedRegistry(fx, [original]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  // The loss is disclosed, not silent: task 6 surfaces this in the run summary.
  expect(result.adopted).toEqual({
    droppedBranches: 2,
    orphanedStorage: devStorage, // still on disk; we never delete it
  });

  // ...and it really is gone from the new entry (this is the loss being reported).
  const entry = (await readRegistry(fx.registryPath)).find((e) => e.name === "widget")!;
  expect(entry.branches).toBeUndefined();
  expect(existsSync(devStorage)).toBe(true); // orphaned, not deleted
});

test("ADOPT of an entry with no branches reports droppedBranches: 0, not a missing field", async () => {
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedDevCloneStorage(fx);
  const { branches, ...noBranches } = collidingEntry(fx);
  seedRegistry(fx, [noBranches as RegistryEntry]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("analyzed");
  expect(result.adopted).toEqual({
    droppedBranches: 0,
    orphanedStorage: join(fx.devClonePath, ".gitnexus"),
  });
});

test("RECALL and first-index report NO adoption -- nothing was dropped", async () => {
  // RECALL merges into our own entry (branches survive), and a first index has
  // nothing to drop. Reporting a loss on either would be a false alarm.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "success");
  seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath: join(fx.cachePath, ".gitnexus"), // ours
      lastCommit: "0000000000000000000000000000000000000000",
      branches: [{ branch: "main", lastCommit: "abc", stats: {} }],
    },
  ]);

  const recalled = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });
  expect(recalled.status).toBe("analyzed");
  expect(recalled.adopted).toBeUndefined();

  const fresh = makeFixture();
  const freshBin = writeMockGitnexus(fresh, "success");
  seedRegistry(fresh, []);
  const first = await refreshGraph(fresh.target, fresh.cachePath, {
    registryPath: fresh.registryPath, cacheRoot: fresh.cacheRoot,
    gitnexusBin: freshBin,
  });
  expect(first.status).toBe("analyzed");
  expect(first.adopted).toBeUndefined();
});

// ---------------------------------------------------------------------------
// clearCacheStorage: the module's only rm. It runs ONLY when it must.
// ---------------------------------------------------------------------------

test("a SPAWN failure does NOT delete the cache storage -- analyze never ran", async () => {
  // gitnexus is a mise shim and may not resolve on PATH under launchd. The
  // process never starts, so the storage on disk is exactly what the last good
  // run left: healthy, hundreds of MB, minutes to rebuild. A self-heal here
  // would nuke every repo's graph on every sweep for as long as PATH is wrong.
  const fx = makeFixture();
  const storagePath = seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath, // ours, so preflight does NOT clear it either
      lastCommit: "0000000000000000000000000000000000000000", // gate misses
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: join(fx.root, "no-such-binary"), // ENOENT on spawn
  });

  expect(result.status).toBe("failed");
  expect(existsSync(join(storagePath, "meta.json"))).toBe(true);
  expect(readFileSync(join(storagePath, "lbug"), "utf8")).toBe("x".repeat(4096));
});

test("a real analyze failure STILL deletes the cache storage (the self-heal is intact)", async () => {
  // The other side of the spawned gate: the process ran, so the index on disk
  // may be partial and unregistered -- which wedges every later sweep.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail");
  const storagePath = seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath,
      lastCommit: "0000000000000000000000000000000000000000",
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath, cacheRoot: fx.cacheRoot,
    gitnexusBin: bin,
  });

  expect(result.status).toBe("failed");
  expect(existsSync(storagePath)).toBe(false);
});

test("a cachePath OUTSIDE the pipeline cache root is REFUSED, never rm -rf'd", async () => {
  // The positive containment guard. Both other guards are vacuous here: the
  // path ends in `.gitnexus` (storageDir always appends it) and it is not under
  // THIS target's dev clone. A task-6 wiring bug handing us some other repo's
  // path would otherwise delete that repo's real index.
  const fx = makeFixture();
  const bin = writeMockGitnexus(fx, "fail"); // spawns, so the self-heal would fire
  const storagePath = seedStorage(fx, fx.devClonePath);
  seedRegistry(fx, [
    {
      name: "widget",
      path: fx.devClonePath,
      storagePath,
      lastCommit: "0000000000000000000000000000000000000000",
    },
  ]);

  const result = await refreshGraph(fx.target, fx.cachePath, {
    registryPath: fx.registryPath,
    // The wiring bug: the cache root does not contain the path we were handed.
    cacheRoot: join(fx.root, "some-other-cache-root"),
    gitnexusBin: bin,
  });

  // The sweep still gets a clean failure -- a refusal never throws...
  expect(result.status).toBe("failed");
  expect(result.error).toBeTruthy();
  // ...and not one byte was deleted.
  expect(existsSync(join(storagePath, "meta.json"))).toBe(true);
  expect(readFileSync(join(storagePath, "lbug"), "utf8")).toBe("x".repeat(4096));
});

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
    { registryPath: fx.registryPath, cacheRoot: fx.cacheRoot, gitnexusBin: bin },
  );

  expect(result.status).toBe("skipped");
  expect(invocation(fx)).toBeNull();
  expect(await readRegistry(fx.registryPath)).toEqual([entry]);
});
