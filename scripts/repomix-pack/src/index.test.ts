import { test, expect } from "bun:test";
import { run, formatSummary } from "./index";
import { readRegistry, type RegistryEntry } from "./registry";
import { formatAdoption } from "./notify";
import {
  mkdtempSync,
  writeFileSync,
  readFileSync,
  mkdirSync,
  existsSync,
  chmodSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

// ---------------------------------------------------------------------------
// SAFETY: every test here injects `registryPath` (temp dir) and a MOCK gitnexus
// binary. Nothing may read or write the real ~/.gitnexus/registry.json (which
// holds real, expensive entries), nothing may touch ~/projects/**, and no real
// `analyze` is ever run (it takes minutes and hundreds of MB).
// ---------------------------------------------------------------------------

interface Fixture {
  root: string;
  bare: string;
  toml: string;
  cacheRoot: string;
  brainRoot: string;
  registryPath: string;
  devRoot: string;
  binPath: string;
  logPath: string;
  configPath: string;
}

const CONFIG_PATH = join(import.meta.dir, "..", "..", "..", "modules/repomix/repomix.config.json");

/**
 * A bare origin for each repo, plus a repos.toml whose `base_dir` points INSIDE
 * the temp root -- so `devClonePath` can never resolve under the real
 * ~/projects/**.
 */
async function makeFixture(repos: string[] = ["widget"]): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), "sweep-"));
  const devRoot = join(root, "dev");
  mkdirSync(devRoot, { recursive: true });

  let bare = "";
  const origins: Record<string, string> = {};
  for (const name of repos) {
    const work = join(root, `work-${name}`);
    mkdirSync(work, { recursive: true });
    await $`git -C ${work} init -q -b main`;
    writeFileSync(join(work, "app.ts"), `export const ${name.replace(/\W/g, "_")} = 1;\n`);
    await $`git -C ${work} add -A`;
    await $`git -C ${work} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init`;
    bare = join(root, `${name}.git`);
    await $`git clone -q --bare ${work} ${bare}`;
    origins[`acme/${name}`] = bare;
  }

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
repos = [${repos.map((r) => JSON.stringify(r)).join(", ")}]
`,
  );

  const fx: Fixture = {
    root,
    bare,
    toml,
    cacheRoot: join(root, "cache"),
    brainRoot: join(root, "brain"),
    registryPath: join(root, "gitnexus", "registry.json"),
    devRoot,
    binPath: join(root, "gitnexus-mock"),
    logPath: join(root, "invocations.log"),
    configPath: CONFIG_PATH,
  };
  (fx as Fixture & { origins: Record<string, string> }).origins = origins;
  return fx;
}

function origins(fx: Fixture): Record<string, string> {
  return (fx as Fixture & { origins: Record<string, string> }).origins;
}

/**
 * Stand-in for the gitnexus binary. Mirrors the real one's observable contract:
 * writes `<repo>/.gitnexus/{meta.json,gitnexus.json}` + a payload file, and
 * registers the alias at the path it analyzed with that path's HEAD as
 * `lastCommit`. It also APPENDS `start <alias>` / `end <alias>` to a shared log,
 * which is how the serialization test proves two analyses never overlap.
 */
function writeMockGitnexus(fx: Fixture, mode: "success" | "fail" = "success"): void {
  const script = `#!/usr/bin/env bun
import { appendFileSync, chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const repoPath = argv[argv.length - 1];
const alias = argv[argv.indexOf("--name") + 1];
const logPath = ${JSON.stringify(fx.logPath)};

appendFileSync(logPath, "start " + alias + "\\n");
// A real analyze takes minutes; this window is enough to expose any overlap.
await new Promise((r) => setTimeout(r, 120));

if (${JSON.stringify(mode)} === "fail") {
  appendFileSync(logPath, "end " + alias + "\\n");
  process.stderr.write("ladybugdb: database is corrupt\\n");
  process.exit(1);
}

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

// gitnexus edits the repo's agent docs as part of analyze -- this is what the
// "any staged diff" PR gate is there to catch.
writeFileSync(join(repoPath, "CLAUDE.md"), "# graph\\nnodes: 7\\n");

const { updateRegistry } = await import(${JSON.stringify(join(import.meta.dir, "registry.ts"))});
await updateRegistry((entries) => {
  const fresh = { name: alias, path: repoPath, storagePath, lastCommit: head, branch: "main" };
  const idx = entries.findIndex((e) => e.name === alias);
  if (idx === -1) return [...entries, fresh];
  const next = [...entries];
  next[idx] = { ...next[idx], ...fresh };
  return next;
}, ${JSON.stringify(fx.registryPath)});

appendFileSync(logPath, "end " + alias + "\\n");
`;
  writeFileSync(fx.binPath, script);
  chmodSync(fx.binPath, 0o755);
}

function seedRegistry(fx: Fixture, entries: RegistryEntry[]): void {
  mkdirSync(join(fx.root, "gitnexus"), { recursive: true });
  writeFileSync(fx.registryPath, JSON.stringify(entries, null, 2));
}

function baseOpts(fx: Fixture) {
  return {
    tomlPath: fx.toml,
    configPath: fx.configPath,
    cacheRoot: fx.cacheRoot,
    brainRoot: fx.brainRoot,
    registryPath: fx.registryPath,
    gitnexusBin: fx.binPath,
    noPr: true,
    noNotify: true,
    originOverride: origins(fx),
  };
}

// --- phase-1 regression -----------------------------------------------------

test("run packs a repo and stages to brain (no PR)", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run({ ...baseOpts(fx), noGraph: true });
  expect(summary.succeeded).toContain("acme/widget");
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);
});

// --- wiring -----------------------------------------------------------------

test("graph stage runs per repo and re-anchors the entry at the dev clone", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  mkdirSync(join(fx.devRoot, "widget"), { recursive: true });

  const summary = await run(baseOpts(fx));

  expect(summary.graph.analyzed).toContain("acme/widget");
  expect(summary.graph.failed).toEqual([]);
  const entries = await readRegistry(fx.registryPath);
  expect(entries).toHaveLength(1);
  // storage stays in the cache; the entry points at the dev clone.
  expect(entries[0].path).toBe(join(fx.devRoot, "widget"));
  expect(entries[0].storagePath).toBe(join(fx.cacheRoot, "acme", "widget", ".gitnexus"));
  // and the pack still ran.
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);
});

test("graph failure never aborts the sweep", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx, "fail");

  const summary = await run(baseOpts(fx));

  expect(summary.failed).toEqual([]); // the REPO did not fail
  expect(summary.succeeded).toContain("acme/widget");
  expect(summary.graph.failed.map((f) => f.slug)).toContain("acme/widget");
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);
});

test("graph stage is serialized even while packs run in parallel", async () => {
  const fx = await makeFixture(["widget", "gadget", "sprocket"]);
  writeMockGitnexus(fx);

  const summary = await run({ ...baseOpts(fx), concurrency: 3 });
  expect(summary.graph.analyzed).toHaveLength(3);

  const lines = readFileSync(fx.logPath, "utf8").trim().split("\n");
  expect(lines).toHaveLength(6);
  // strict start/end pairing == no two analyses ever overlapped.
  for (let i = 0; i < lines.length; i += 2) {
    const [sVerb, sAlias] = lines[i].split(" ");
    const [eVerb, eAlias] = lines[i + 1].split(" ");
    expect(sVerb).toBe("start");
    expect(eVerb).toBe("end");
    expect(eAlias).toBe(sAlias);
  }
});

// --- flags ------------------------------------------------------------------

test("--no-graph skips the graph stage entirely", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run({ ...baseOpts(fx), noGraph: true });
  expect(summary.graph.analyzed).toEqual([]);
  expect(summary.graph.skipped).toContain("acme/widget");
  expect(existsSync(fx.logPath)).toBe(false); // analyze never spawned
  expect(existsSync(fx.registryPath)).toBe(false); // registry never written
});

test("--graph-only skips packing but still runs the graph", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run({ ...baseOpts(fx), graphOnly: true });
  expect(summary.graph.analyzed).toContain("acme/widget");
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(false); // no pack
});

test("--dry-run runs neither analyze nor a registry write", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run({ ...baseOpts(fx), dryRun: true });
  expect(existsSync(fx.logPath)).toBe(false);
  expect(existsSync(fx.registryPath)).toBe(false);
  expect(summary.graph.analyzed).toEqual([]);
  expect(summary.graph.skipped).toContain("acme/widget");
});

test("--graph-only and --no-graph together are refused", async () => {
  const fx = await makeFixture();
  expect(run({ ...baseOpts(fx), graphOnly: true, noGraph: true })).rejects.toThrow(
    /graph-only.*no-graph/i,
  );
});

test("graph: false in repos.toml opts the repo out (caller-side gate)", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  writeFileSync(
    fx.toml,
    `${readFileSync(fx.toml, "utf8")}\n[repo."acme/widget"]\ngraph = false\n`,
  );
  const summary = await run(baseOpts(fx));
  expect(summary.graph.skipped).toContain("acme/widget");
  expect(existsSync(fx.logPath)).toBe(false); // never even spawned
});

// --- disk budget + prune ----------------------------------------------------

test("reports total graph cache size for the sweep", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run(baseOpts(fx));
  expect(summary.graph.cacheBytes).toBeGreaterThan(4096);
});

test("prunes graphs + registry entries for repos no longer in repos.toml, and nothing else", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);

  // A graph left behind by a repo that has since been removed from repos.toml.
  const ghost = join(fx.cacheRoot, "acme", "ghost", ".gitnexus");
  mkdirSync(ghost, { recursive: true });
  writeFileSync(join(ghost, "lbug"), "x".repeat(64));
  // A foreign entry -- one of the user's own, storage OUTSIDE our cache root.
  const foreignStorage = join(fx.root, "elsewhere", "moneta", ".gitnexus");
  mkdirSync(foreignStorage, { recursive: true });
  seedRegistry(fx, [
    { name: "ghost", path: join(fx.devRoot, "ghost"), storagePath: ghost },
    { name: "moneta", path: join(fx.root, "elsewhere", "moneta"), storagePath: foreignStorage },
  ]);

  const summary = await run(baseOpts(fx));

  expect(summary.graph.prunedGraphs).toContain("acme/ghost");
  expect(existsSync(ghost)).toBe(false);
  const names = (await readRegistry(fx.registryPath)).map((e) => e.name).sort();
  expect(names).toEqual(["moneta", "widget"]); // ghost gone, foreign entry untouched
  expect(existsSync(foreignStorage)).toBe(true); // its STORAGE is never touched
});

test("prune is not fooled by --only/--group narrowing the sweep", async () => {
  const fx = await makeFixture(["widget", "gadget"]);
  writeMockGitnexus(fx);
  const gadgetGraph = join(fx.cacheRoot, "acme", "gadget", ".gitnexus");
  mkdirSync(gadgetGraph, { recursive: true });
  writeFileSync(join(gadgetGraph, "lbug"), "x".repeat(64));
  seedRegistry(fx, [
    { name: "gadget", path: join(fx.devRoot, "gadget"), storagePath: gadgetGraph },
  ]);

  // gadget is in repos.toml but NOT in this run's --only filter.
  await run({ ...baseOpts(fx), only: ["acme/widget"] });

  expect(existsSync(gadgetGraph)).toBe(true);
  const names = (await readRegistry(fx.registryPath)).map((e) => e.name).sort();
  expect(names).toEqual(["gadget", "widget"]);
});

// --- adoption disclosure ----------------------------------------------------

test("adoption is surfaced in the summary and in Slack", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const devClone = join(fx.devRoot, "widget");
  const orphaned = join(devClone, ".gitnexus");
  mkdirSync(orphaned, { recursive: true });
  writeFileSync(join(orphaned, "lbug"), "x".repeat(2048));
  seedRegistry(fx, [
    {
      name: "widget",
      path: devClone,
      storagePath: orphaned,
      branches: [{ name: "release/v2", storagePath: join(orphaned, "branches", "release-v2") }],
    },
  ]);

  const posted: object[] = [];
  const summary = await run({
    ...baseOpts(fx),
    noNotify: false,
    webhook: "https://example.invalid/hook",
    postSlack: async (_w, payload) => {
      posted.push(payload);
    },
  });

  expect(summary.graph.adoptions).toHaveLength(1);
  const a = summary.graph.adoptions[0];
  expect(a.slug).toBe("acme/widget");
  expect(a.droppedBranches).toBe(1);
  expect(a.orphanedStorage).toBe(orphaned);
  expect(a.bytes).toBeGreaterThan(2000);

  // ...and the user is TOLD, in both channels.
  const table = formatSummary(summary);
  expect(table).toContain("adopted acme/widget");
  expect(table).toContain(orphaned);
  const slack = JSON.stringify(posted);
  expect(slack).toContain("adopted acme/widget");
  expect(slack).toContain(orphaned);

  // the dev clone's old index is left ON DISK -- we never delete under ~/projects
  expect(existsSync(join(orphaned, "lbug"))).toBe(true);
});

test("formatAdoption states the loss plainly", () => {
  const one = formatAdoption({
    slug: "nwlnexus/olympus-sdk",
    droppedBranches: 1,
    orphanedStorage: "/Users/x/projects/personal/olympus-sdk/.gitnexus",
    bytes: 318 * 1024 * 1024,
  });
  expect(one).toContain("adopted nwlnexus/olympus-sdk");
  expect(one).toContain("1 multi-branch index no longer registered");
  expect(one).toContain("/Users/x/projects/personal/olympus-sdk/.gitnexus");
  expect(one).toContain("318 MB");
  expect(one).toMatch(/delete it to reclaim space|re-index/i);

  const none = formatAdoption({
    slug: "acme/widget",
    droppedBranches: 0,
    orphanedStorage: "/Users/x/projects/personal/widget/.gitnexus",
    bytes: 1024,
  });
  expect(none).toContain("adopted acme/widget");
  expect(none).not.toContain("multi-branch index no longer registered");
});

// --- summary ----------------------------------------------------------------

test("summary table carries the graph column and the cache size", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const summary = await run(baseOpts(fx));
  const table = formatSummary(summary);
  expect(table).toContain("acme/widget");
  expect(table).toContain("analyzed");
  expect(table).toMatch(/graph cache:\s+[\d.]+ (KB|MB|GB|B)/i);
});

// --- phase-1 invariant ------------------------------------------------------

test("a second sweep at the same commit re-analyzes nothing and notifies nobody", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  mkdirSync(join(fx.devRoot, "widget"), { recursive: true });

  const posted: object[] = [];
  const opts = {
    ...baseOpts(fx),
    noNotify: false,
    webhook: "https://example.invalid/hook",
    postSlack: async (_w: string, p: object) => {
      posted.push(p);
    },
  };

  const first = await run(opts);
  expect(first.graph.analyzed).toContain("acme/widget");

  const second = await run(opts);
  // HEAD hasn't moved and the cache storage survived checkout's `git clean`,
  // so the commit gate holds: no analyze, no adoption, nothing to say.
  expect(second.graph.analyzed).toEqual([]);
  expect(second.graph.skipped).toContain("acme/widget");
  expect(readFileSync(fx.logPath, "utf8").trim().split("\n")).toHaveLength(2);
  expect(second.graph.adoptions).toEqual([]);
  expect(second.prs).toEqual([]);
  expect(posted).toEqual([]);
});
