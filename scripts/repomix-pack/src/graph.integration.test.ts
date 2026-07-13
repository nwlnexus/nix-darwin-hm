import { test, expect, mock } from "bun:test";
import * as gitPrModule from "./git-pr";
import { run, type RunSummary } from "./index";
import { readRegistry } from "./registry";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { $ } from "bun";

// ---------------------------------------------------------------------------
// END-TO-END seam of the graph stage: checkout -> pack -> analyze -> re-anchor
// -> PR, driven through the real `run()` against a sandbox origin.
//
// This file is NOT a second copy of graph.test.ts/index.test.ts. It asserts the
// four properties the design spike established, and only those:
//
//   1. analyze runs in the CACHE, the entry is re-anchored at the DEV CLONE, and
//      a working-tree-sensitive query for the alias therefore lands in the dev
//      clone -- not the cache. (The load-bearing property of the whole design.)
//   2. the dev clone stays byte-identical: no `.gitnexus`, no injected
//      CLAUDE.md/AGENTS.md/.claude/skills.
//   3. a graph-only change (pack byte-identical to base) still opens a PR.
//   4. an unchanged repo no-ops: no analyze, no PR, no notification.
//
// SAFETY: `registryPath`, `cacheRoot` and the repos.toml `base_dir` all point
// inside a temp dir; the gitnexus binary is always a MOCK. Nothing here may read
// or write the real ~/.gitnexus/registry.json or anything under ~/projects/**,
// and no real `analyze` is ever spawned (14s+ and hundreds of MB per repo).
// ---------------------------------------------------------------------------

const CONFIG_PATH = join(import.meta.dir, "..", "..", "..", "modules/repomix/repomix.config.json");

/** Snapshot of the REAL ./git-pr exports, taken before any mock.module call. */
const REAL_GIT_PR = { ...gitPrModule };

interface Fixture {
  root: string;
  bare: string;
  work: string;
  toml: string;
  cacheRoot: string;
  cachePath: string;
  brainRoot: string;
  registryPath: string;
  devClone: string;
  binPath: string;
  logPath: string;
  origins: Record<string, string>;
}

function git(args: string[], cwd: string): string {
  const res = Bun.spawnSync(
    ["git", "-c", "commit.gpgsign=false", "-c", "user.email=t@t", "-c", "user.name=t", ...args],
    { cwd },
  );
  if (res.exitCode !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${res.stderr.toString()}`);
  }
  return res.stdout.toString().trim();
}

/**
 * A bare origin whose `main` ALREADY CARRIES the exact pack repomix will
 * regenerate, plus a real dev clone of it.
 *
 * Committing the pack to base is what makes properties 3 and 4 real rather than
 * mocked: `packChanged` diffs the regenerated pack against `HEAD:<packPath>`, so
 * with the pack on base the sweep's pack stage genuinely reports "unchanged"
 * (repomix's output is deterministic and directory-independent, and its config
 * ignores `.llm/**`, so the committed pack does not perturb the next one). The
 * only thing that can then produce a PR is the graph stage's CLAUDE.md/AGENTS.md
 * -- which is exactly the regression under test.
 */
function makeFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "graph-e2e-"));
  const devRoot = join(root, "dev");
  mkdirSync(devRoot, { recursive: true });

  const work = join(root, "work");
  mkdirSync(work, { recursive: true });
  git(["init", "-q", "-b", "main", "."], work);
  writeFileSync(join(work, "app.ts"), "export const widget = 1;\n");
  git(["add", "-A"], work);
  git(["commit", "-qm", "init"], work);

  // Seed base with the pack the sweep will produce, byte for byte.
  const pack = Bun.spawnSync(["repomix", "--config", CONFIG_PATH, "."], { cwd: work });
  if (pack.exitCode !== 0) throw new Error(`repomix seed failed: ${pack.stderr.toString()}`);
  git(["add", "-f", ".llm/repomix.xml"], work);
  git(["commit", "-qm", "pack"], work);

  const bare = join(root, "widget.git");
  git(["clone", "-q", "--bare", work, bare], root);

  // The user's real dev clone. Never ours to write to.
  const devClone = join(devRoot, "widget");
  git(["clone", "-q", bare, devClone], root);

  const toml = join(root, "repos.toml");
  writeFileSync(
    toml,
    `
[defaults]
pack_path = ".llm/repomix.xml"
branch = "automation/repomix-pack"
[groups.personal]
base_dir = ${JSON.stringify(devRoot)}
ssh_host = "github.com"
owner = "acme"
repos = ["widget"]
`,
  );

  const cacheRoot = join(root, "cache");
  return {
    root,
    bare,
    work,
    toml,
    cacheRoot,
    cachePath: join(cacheRoot, "acme", "widget"),
    brainRoot: join(root, "brain"),
    registryPath: join(root, "gitnexus", "registry.json"),
    devClone,
    binPath: join(root, "gitnexus-mock"),
    logPath: join(root, "invocations.log"),
    origins: { "acme/widget": bare },
  };
}

/**
 * Stand-in for the gitnexus binary, with two subcommands:
 *
 *  - `analyze --name <alias> <path>`: writes `<path>/.gitnexus/{meta,gitnexus}.json`
 *    + a payload, INJECTS `CLAUDE.md`, `AGENTS.md` and `.claude/skills/**` into
 *    `<path>`, and registers the alias AT THE PATH IT ANALYZED. It injects the
 *    skills dir even though the sweep passes `--skip-skills`: property 2 must
 *    hold even for a gitnexus that ignores that flag, so the mock is deliberately
 *    the worst case.
 *
 *  - `detect-changes -r <alias>`: the working-tree-sensitive consumer. Resolves
 *    the alias THROUGH THE REGISTRY THIS SWEEP WROTE (entry.path is the repo
 *    root) and reports that tree's dirty files. This is a PROXY for real
 *    gitnexus -- the resolution rule is reimplemented here -- but the registry it
 *    reads is the genuine post-sweep artifact.
 */
function writeMockGitnexus(fx: Fixture): void {
  const script = `#!/usr/bin/env bun
import { appendFileSync, chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const registryPath = ${JSON.stringify(fx.registryPath)};
const logPath = ${JSON.stringify(fx.logPath)};

function aliasOf() {
  const i = argv.findIndex((a) => a === "--name" || a === "-r");
  return argv[i + 1];
}

if (argv[0] === "detect-changes") {
  const { readRegistry } = await import(${JSON.stringify(join(import.meta.dir, "registry.ts"))});
  const entry = (await readRegistry(registryPath)).find((e) => e.name === aliasOf());
  if (!entry) { process.stderr.write("no such repo\\n"); process.exit(1); }
  const status = Bun.spawnSync(["git", "-C", entry.path, "status", "--porcelain"]).stdout.toString();
  process.stdout.write("repo " + entry.path + "\\n" + status);
  process.exit(0);
}

const repoPath = argv[argv.length - 1];
const alias = aliasOf();
appendFileSync(logPath, "analyze " + alias + " " + repoPath + "\\n");

const head = Bun.spawnSync(["git", "-C", repoPath, "rev-parse", "HEAD"]).stdout.toString().trim();
const storagePath = join(repoPath, ".gitnexus");
mkdirSync(storagePath, { recursive: true });
const meta = {
  repoPath,
  lastCommit: head,
  indexedAt: new Date().toISOString(),
  branch: "main",
  stats: { files: 1, nodes: 7, edges: 3 },
};
for (const f of ["meta.json", "gitnexus.json"]) {
  writeFileSync(join(storagePath, f), JSON.stringify(meta, null, 2));
  chmodSync(join(storagePath, f), 0o600);
}
writeFileSync(join(storagePath, "lbug"), "x".repeat(4096));

// Everything a real analyze injects into the repo it is pointed at.
writeFileSync(join(repoPath, "CLAUDE.md"), "# graph\\nnodes: 7\\n");
writeFileSync(join(repoPath, "AGENTS.md"), "# graph\\nnodes: 7\\n");
mkdirSync(join(repoPath, ".claude", "skills", "graph"), { recursive: true });
writeFileSync(join(repoPath, ".claude", "skills", "graph", "SKILL.md"), "# skill\\n");

const { updateRegistry } = await import(${JSON.stringify(join(import.meta.dir, "registry.ts"))});
await updateRegistry((entries) => {
  const fresh = { name: alias, path: repoPath, storagePath, lastCommit: head, branch: "main" };
  const idx = entries.findIndex((e) => e.name === alias);
  if (idx === -1) return [...entries, fresh];
  const next = [...entries];
  next[idx] = { ...next[idx], ...fresh };
  return next;
}, registryPath);
`;
  writeFileSync(fx.binPath, script);
  chmodSync(fx.binPath, 0o755);
}

interface PrCall {
  slug: string;
  base: string;
  body: string;
}

/**
 * Run the sweep with the REAL `commitToBranch` (real git, real force-push to the
 * sandbox bare origin, real "any staged diff against base" gate) and only
 * `openOrUpdatePr` stubbed -- it shells out to `gh`, which cannot reach a temp
 * dir origin. The PR GATE is therefore exercised for real; only the GitHub API
 * call is faked.
 */
async function sweep(
  fx: Fixture,
  extra: Record<string, unknown> = {},
): Promise<{ summary: RunSummary; prs: PrCall[]; posted: object[] }> {
  const prs: PrCall[] = [];
  const posted: object[] = [];
  mock.module("./git-pr", () => ({
    ...REAL_GIT_PR,
    openOrUpdatePr: async (target: { slug: string }, base: string, _t: string, body: string) => {
      prs.push({ slug: target.slug, base, body });
      return { url: `https://github.invalid/${target.slug}/pull/1`, created: true };
    },
  }));
  try {
    const summary = await run({
      tomlPath: fx.toml,
      configPath: CONFIG_PATH,
      cacheRoot: fx.cacheRoot,
      brainRoot: fx.brainRoot,
      registryPath: fx.registryPath,
      gitnexusBin: fx.binPath,
      originOverride: fx.origins,
      webhook: "https://example.invalid/hook",
      postSlack: async (_w: string, p: object) => {
        posted.push(p);
      },
      ...extra,
    });
    return { summary, prs, posted };
  } finally {
    mock.module("./git-pr", () => ({ ...REAL_GIT_PR })); // never leak the stub
  }
}

/** relpath -> sha256+mode, for every file in `dir` except git's own metadata. */
function snapshot(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (d: string) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) {
        if (relative(dir, p) === ".git") continue; // git's own bookkeeping, not the worktree
        walk(p);
      } else if (e.isFile()) {
        const h = createHash("sha256").update(readFileSync(p)).digest("hex");
        out[relative(dir, p)] = `${h}:${(statSync(p).mode & 0o7777).toString(8)}`;
      }
    }
  };
  walk(dir);
  return out;
}

function analyzedPaths(fx: Fixture): string[] {
  if (!existsSync(fx.logPath)) return [];
  return readFileSync(fx.logPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => l.split(" ")[2]);
}

// --- property 1 -------------------------------------------------------------

test("analyze runs in the cache, the entry is re-anchored at the dev clone, and a working-tree query resolves to the DEV CLONE", async () => {
  const fx = makeFixture();
  writeMockGitnexus(fx);

  const { summary } = await sweep(fx);
  expect(summary.graph.analyzed).toContain("acme/widget");
  expect(summary.graph.failed).toEqual([]);

  // What was analyzed: the cache checkout, never the dev clone.
  expect(analyzedPaths(fx)).toEqual([fx.cachePath]);

  // The re-anchored state: `path` is the dev clone, `storagePath` stays in the cache.
  const entries = await readRegistry(fx.registryPath);
  expect(entries).toHaveLength(1);
  expect(entries[0].path).toBe(fx.devClone);
  expect(entries[0].storagePath).toBe(join(fx.cachePath, ".gitnexus"));
  expect(existsSync(join(fx.cachePath, ".gitnexus", "meta.json"))).toBe(true);
  expect(existsSync(join(fx.devClone, ".gitnexus"))).toBe(false);

  // ...and BOTH storage manifests were rewritten to point at the dev clone, which
  // is what stops gitnexus resolving the graph back to the cache behind our back.
  for (const f of ["meta.json", "gitnexus.json"]) {
    const m = JSON.parse(readFileSync(join(fx.cachePath, ".gitnexus", f), "utf8"));
    expect(m.repoPath).toBe(fx.devClone);
    expect(m.stats.nodes).toBe(7); // gitnexus's own fields survived the rewrite
  }

  // The consequence, exercised: a working-tree-sensitive query for the alias must
  // read the DEV CLONE. Dirty the dev clone; plant a decoy in the cache checkout.
  writeFileSync(join(fx.devClone, "wip.ts"), "export const wip = 1;\n");
  writeFileSync(join(fx.cachePath, "decoy.ts"), "export const decoy = 1;\n");

  const dc = Bun.spawnSync([fx.binPath, "detect-changes", "-r", "widget"]);
  expect(dc.exitCode).toBe(0);
  const out = dc.stdout.toString();
  expect(out).toContain(`repo ${fx.devClone}`);
  expect(out).toContain("wip.ts"); // the DEV CLONE's working tree
  expect(out).not.toContain("decoy.ts"); // ...and not the cache's
  expect(out).not.toContain(fx.cachePath);
});

// --- property 2 -------------------------------------------------------------

test("the sweep never writes into the dev clone: no .gitnexus, no injected files, byte-identical", async () => {
  const fx = makeFixture();
  writeMockGitnexus(fx);

  const before = snapshot(fx.devClone);
  expect(Object.keys(before).sort()).toEqual([".llm/repomix.xml", "app.ts"]);

  const { summary } = await sweep(fx);
  expect(summary.graph.analyzed).toContain("acme/widget");

  // Byte-identical, mode included.
  expect(snapshot(fx.devClone)).toEqual(before);

  // Named explicitly, because these are the exact files a mispointed analyze
  // would have dropped in the user's repo.
  for (const p of [".gitnexus", "CLAUDE.md", "AGENTS.md", ".claude"]) {
    expect(existsSync(join(fx.devClone, p))).toBe(false);
  }
  // The hermetic form of the pilot's `git status` check.
  expect((await $`git -C ${fx.devClone} status --porcelain`.text()).trim()).toBe("");

  // Non-vacuous: the mock DID inject all of it -- into the cache checkout, which
  // is the only place it is allowed to land.
  for (const p of [".gitnexus/meta.json", "CLAUDE.md", "AGENTS.md", ".claude/skills/graph/SKILL.md"]) {
    expect(existsSync(join(fx.cachePath, p))).toBe(true);
  }
});

// --- property 3 -------------------------------------------------------------

test("a graph-only change still opens a PR: pack byte-identical to base, CLAUDE.md changed", async () => {
  // Control, so the assertion below cannot pass for the wrong reason: with the
  // graph stage OFF, this exact repo produces no staged diff at all and no PR.
  // Whatever the real sweep publishes is therefore the graph's doing.
  const control = makeFixture();
  writeMockGitnexus(control);
  const off = await sweep(control, { noGraph: true });
  expect(off.prs).toEqual([]);
  expect(off.summary.skipped).toContain("acme/widget");

  const fx = makeFixture();
  writeMockGitnexus(fx);

  const { summary, prs, posted } = await sweep(fx);

  // The pack really is unchanged: base already carries the byte-exact pack, so
  // packChanged said "no" and the brain sink was never written. (This is the end
  // of the old PR gate -- pre-fix, `gate.changed` gated the commit and this sweep
  // would have published nothing.)
  expect(existsSync(join(fx.brainRoot, "acme", "widget.xml"))).toBe(false);

  // ...and a PR was opened anyway, because commitToBranch gates on ANY staged
  // diff against base -- here, the graph stage's CLAUDE.md/AGENTS.md.
  expect(summary.graph.analyzed).toContain("acme/widget");
  expect(prs).toHaveLength(1);
  expect(prs[0].slug).toBe("acme/widget");
  expect(prs[0].base).toBe("main");
  expect(summary.prs.map((p) => p.slug)).toEqual(["acme/widget"]);
  expect(summary.succeeded).toContain("acme/widget");
  expect(posted).toHaveLength(1); // and Slack was told

  // The commit really landed on the automation branch of the origin, and it is a
  // GRAPH-ONLY commit: docs added, pack identical to base's.
  const branch = "automation/repomix-pack";
  const tree = await $`git -C ${fx.bare} ls-tree -r --name-only ${branch}`.text();
  expect(tree).toContain("CLAUDE.md");
  expect(tree).toContain("AGENTS.md");
  const onBranch = await $`git -C ${fx.bare} rev-parse ${branch + ":.llm/repomix.xml"}`.text();
  const onBase = await $`git -C ${fx.bare} rev-parse ${"main:.llm/repomix.xml"}`.text();
  expect(onBranch.trim()).toBe(onBase.trim()); // the pack blob did not move
});

// --- property 4 -------------------------------------------------------------

test("an unchanged repo no-ops: no analyze, no PR, no notification", async () => {
  const fx = makeFixture();
  writeMockGitnexus(fx);
  const branch = "automation/repomix-pack";
  const devBefore = snapshot(fx.devClone);

  const first = await sweep(fx);
  expect(first.summary.graph.analyzed).toContain("acme/widget");
  expect(analyzedPaths(fx)).toHaveLength(1);
  const shaAfterFirst = (await $`git -C ${fx.bare} rev-parse ${branch}`.text()).trim();

  // Nothing moved: same HEAD, cache storage survived checkout's `git clean`.
  const second = await sweep(fx);

  expect(second.summary.graph.analyzed).toEqual([]);
  expect(second.summary.graph.skipped).toContain("acme/widget");
  expect(second.summary.graph.adoptions).toEqual([]);
  expect(analyzedPaths(fx)).toHaveLength(1); // analyze never spawned a second time

  expect(second.prs).toEqual([]); // no PR opened or updated
  expect(second.summary.prs).toEqual([]);
  expect(second.posted).toEqual([]); // nobody notified
  expect(second.summary.skipped).toContain("acme/widget"); // pack + commit both no-op
  // ...and the automation branch was not force-pushed over.
  expect((await $`git -C ${fx.bare} rev-parse ${branch}`.text()).trim()).toBe(shaAfterFirst);

  // The entry stays re-anchored at the dev clone across the skip path, which is
  // what stops anchor drift silently sending `rename` into the cache checkout.
  const entries = await readRegistry(fx.registryPath);
  expect(entries[0].path).toBe(fx.devClone);
  expect(entries[0].storagePath).toBe(join(fx.cachePath, ".gitnexus"));
  // ...and two sweeps later the dev clone is still untouched.
  expect(snapshot(fx.devClone)).toEqual(devBefore);
});
