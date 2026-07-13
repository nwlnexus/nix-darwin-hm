import { test, expect, mock } from "bun:test";
import * as packModule from "./pack";
import { run, formatSummary, graphFailed } from "./index";
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
  /** The working clone the last bare origin was made from; push to move HEAD. */
  work: string;
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

/** Snapshot of the REAL ./pack exports, taken before any mock.module call. */
const REAL_PACK = { ...packModule };

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
  let lastWork = "";
  const origins: Record<string, string> = {};
  for (const name of repos) {
    const work = join(root, `work-${name}`);
    lastWork = work;
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
    work: lastWork,
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

/**
 * Run `fn` with the REAL `runPack` wrapped in an in-flight counter, and report
 * the peak number of packs that were running at the same time.
 *
 * This is what makes the serialization test falsifiable. Strict start/end
 * pairing in the analyze log proves the graph stage never overlapped -- but on
 * its own it would hold just as well for a sweep accidentally forced to
 * concurrency 1. `peak > 1` proves the parallelism the graph stage is serialized
 * AGAINST actually existed.
 */
async function withPackTrace<T>(fn: () => Promise<T>): Promise<{ result: T; peak: number }> {
  let open = 0;
  let peak = 0;
  mock.module("./pack", () => ({
    ...REAL_PACK,
    runPack: async (dir: string, configPath: string) => {
      peak = Math.max(peak, ++open);
      try {
        // REAL_PACK, not packModule: the module namespace is a LIVE binding, so
        // after mock.module `packModule.runPack` IS this wrapper -- and calling
        // it here would recurse forever.
        return await REAL_PACK.runPack(dir, configPath);
      } finally {
        open--;
      }
    },
  }));
  try {
    return { result: await fn(), peak };
  } finally {
    mock.module("./pack", () => ({ ...REAL_PACK })); // never leak the wrapper
  }
}

/** The file paths repomix actually packed (its `<directory_structure>` block). */
function packedPaths(xml: string): string[] {
  const m = xml.match(/<directory_structure>([\s\S]*?)<\/directory_structure>/);
  return (m?.[1] ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
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

test("the graph storage is never packed, even on the sweep that finds it there", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);

  // Sweep 1 packs a tree with no .gitnexus (the graph is written AFTER the pack).
  await run(baseOpts(fx));
  // Sweep 2 packs a tree that HAS one -- `git clean -e /.gitnexus` keeps it.
  await run(baseOpts(fx));

  const checkout = join(fx.cacheRoot, "acme", "widget");
  // The pessimistic case, deliberately: the mock writes NO self-ignoring
  // `.gitnexus/.gitignore`. Real gitnexus 1.6.9 happens to, but relying on that
  // means any version that stops doing it silently balloons every pack (a 200 KB
  // WAL alone was 186k tokens) and force-pushes it as a PR. Only repomix's own
  // ignore list may stand between us and that.
  expect(existsSync(join(checkout, ".gitnexus", "lbug"))).toBe(true);
  expect(existsSync(join(checkout, ".gitnexus", ".gitignore"))).toBe(false);

  const pack = readFileSync(join(checkout, ".llm", "repomix.xml"), "utf8");
  expect(packedPaths(pack)).toEqual(["app.ts"]); // nothing from .gitnexus, nothing else
  expect(pack).not.toContain('path=".gitnexus'); // no graph file was inlined...
  expect(pack).not.toContain("x".repeat(64)); // ...and neither was the WAL payload
  expect(pack).toContain(".gitnexus/**"); // repomix's OWN ignore list is what did it

  const staged = readFileSync(join(fx.brainRoot, "acme/widget.xml"), "utf8");
  expect(packedPaths(staged)).toEqual(["app.ts"]);
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

  const { result: summary, peak } = await withPackTrace(() =>
    run({ ...baseOpts(fx), concurrency: 3 }),
  );
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

  // ...and the packs it is serialized AGAINST really did overlap. Without this
  // the pairing above is vacuous: it would hold just as well for a sweep
  // accidentally forced to concurrency 1.
  expect(peak).toBeGreaterThan(1);
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

test("--graph-only implies --no-pr: it never rewrites a pending pack PR", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const branch = "automation/repomix-pack";

  // sweep 1 (full) publishes the pack onto the automation branch == the open PR.
  await run(baseOpts(fx));
  const beforeSha = (await $`git -C ${fx.bare} rev-parse ${branch}`.text()).trim();
  expect(await $`git -C ${fx.bare} ls-tree -r --name-only ${branch}`.text()).toContain(
    ".llm/repomix.xml",
  );

  // The repo moves on: the graph is now stale (so a --graph-only sweep really
  // re-analyzes, and gitnexus rewrites CLAUDE.md) while the pack PR is still open.
  writeFileSync(join(fx.work, "next.ts"), "export const next = 2;\n");
  await $`git -C ${fx.work} add -A`.quiet();
  await $`git -C ${fx.work} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm next`.quiet();
  await $`git -C ${fx.work} push -q ${fx.bare} main`.quiet();

  const summary = await run({ ...baseOpts(fx), graphOnly: true });

  expect(summary.graph.analyzed).toContain("acme/widget"); // the graph DID refresh
  expect(summary.publishSkipped).toBe(true); // ...and it is SAID so
  expect(formatSummary(summary)).toContain("--graph-only");
  expect(summary.prs).toEqual([]);
  // The open PR's branch is byte-identical: no force-push, so the pending pack
  // commit is still in it (pre-fix the branch was rewritten from base and the
  // pack silently dropped).
  expect((await $`git -C ${fx.bare} rev-parse ${branch}`.text()).trim()).toBe(beforeSha);
  expect(await $`git -C ${fx.bare} ls-tree -r --name-only ${branch}`.text()).toContain(
    ".llm/repomix.xml",
  );
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

test("prune drops the departed repo's whole cache dir, checkout included", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);

  // A repo that has since left repos.toml: a full checkout AND its graph.
  const ghost = join(fx.cacheRoot, "acme", "ghost");
  mkdirSync(join(ghost, ".git"), { recursive: true });
  mkdirSync(join(ghost, ".gitnexus"), { recursive: true });
  writeFileSync(join(ghost, "big.bin"), "x".repeat(8192));

  const summary = await run(baseOpts(fx));

  expect(summary.graph.prunedGraphs).toContain("acme/ghost");
  expect(existsSync(ghost)).toBe(false); // the CHECKOUT goes too, not just .gitnexus
  // ...and the live repo's cache dir is untouched.
  expect(existsSync(join(fx.cacheRoot, "acme", "widget", ".git"))).toBe(true);
});

test("prune never eats the brain staging dir that lives inside the cache root", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  const brainRoot = join(fx.cacheRoot, "brain-staging"); // the PRODUCTION shape

  await run({ ...baseOpts(fx), brainRoot });
  const staged = join(brainRoot, "acme", "widget.xml");
  expect(existsSync(staged)).toBe(true);

  const second = await run({ ...baseOpts(fx), brainRoot });
  expect(second.graph.prunedGraphs).toEqual([]);
  expect(existsSync(staged)).toBe(true);
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

test("graph = false AFTER a graph was built prunes the stale graph + entry -- but keeps the checkout", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);

  await run(baseOpts(fx)); // sweep 1: graphed
  const graphDir = join(fx.cacheRoot, "acme", "widget", ".gitnexus");
  expect(existsSync(graphDir)).toBe(true);
  expect((await readRegistry(fx.registryPath)).map((e) => e.name)).toEqual(["widget"]);

  // The user opts the repo out. Before this fix, the graph, the registry entry
  // and the whole cache dir simply stayed -- forever, with nothing left in the
  // pipeline that would ever revisit them, while `gitnexus -r widget` went on
  // serving the entry as if it were current.
  //
  // (A NEW toml path, not an edit in place: loadTargets goes through `require`,
  // which caches by path for the life of the process. A real sweep is a fresh
  // process every time, so this is a test artifact -- but editing fx.toml here
  // would silently re-load the OLD config and the test would prove nothing.)
  const optedOut = join(fx.root, "repos-opted-out.toml");
  writeFileSync(optedOut, `${readFileSync(fx.toml, "utf8")}\n[repo."acme/widget"]\ngraph = false\n`);
  const second = await run({ ...baseOpts(fx), tomlPath: optedOut });

  expect(second.graph.prunedOptOuts).toContain("acme/widget");
  expect(existsSync(graphDir)).toBe(false); // the stale graph is gone...
  expect(await readRegistry(fx.registryPath)).toEqual([]); // ...and so is its entry
  expect(formatSummary(second)).toContain("graph = false");

  // ...but the CHECKOUT stays: the repo is still IN repos.toml and is still
  // packed on every sweep. Dropping it would mean a full re-clone every run.
  expect(existsSync(join(fx.cacheRoot, "acme", "widget", ".git"))).toBe(true);
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);
});

// --- graph failures are visible ---------------------------------------------

test("a broken graph stage is LOUD: it posts to Slack and it is not exit 0", async () => {
  // The safety net for the launchd bug. A graph stage that fails for every repo
  // on every scheduled run used to look EXACTLY like a clean sweep: exit 0, no
  // Slack, packs still flowing. Isolation is about control flow, not silence.
  const fx = await makeFixture();
  writeMockGitnexus(fx, "fail");

  const posted: object[] = [];
  const summary = await run({
    ...baseOpts(fx),
    noNotify: false,
    webhook: "https://example.invalid/hook",
    postSlack: async (_w, p) => {
      posted.push(p);
    },
  });

  // isolation still holds: the repo packed, and its branch was published.
  expect(summary.failed).toEqual([]);
  expect(summary.succeeded).toContain("acme/widget");
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);

  // ...and the failure is impossible to miss.
  expect(summary.graph.failed.map((f) => f.slug)).toEqual(["acme/widget"]);
  expect(graphFailed(summary)).toBe(true); // -> the CLI exits 1
  const slack = JSON.stringify(posted);
  expect(slack).toContain("acme/widget");
  expect(slack).toMatch(/FAILED/i);
  expect(slack).toContain("database is corrupt"); // the real error, not a generic one
});

test("one Slack post for a graph failure, not one per repo", async () => {
  // A systemic breakage (the binary doesn't resolve) fails all N at once. N
  // identical messages is how a channel gets muted.
  const fx = await makeFixture(["widget", "gadget", "sprocket"]);
  writeMockGitnexus(fx, "fail");

  const posted: object[] = [];
  const summary = await run({
    ...baseOpts(fx),
    noNotify: false,
    webhook: "https://example.invalid/hook",
    postSlack: async (_w, p) => {
      posted.push(p);
    },
  });

  expect(summary.graph.failed).toHaveLength(3);
  expect(posted).toHaveLength(1);
  const text = JSON.stringify(posted[0]);
  for (const slug of ["acme/widget", "acme/gadget", "acme/sprocket"]) {
    expect(text).toContain(slug); // every repo still named
  }
});

// --- prune isolation --------------------------------------------------------

test("a corrupt registry costs the graph, never the packs", async () => {
  // pruneGraphs reads AND writes the registry, and it runs BEFORE the pack
  // stage. Unguarded it threw straight out of run(): a corrupt registry.json --
  // or a wedged 10s lock -- would have taken down the entire sweep, packs and
  // PRs included, for all 11 repos. Before the graph stage existed the registry
  // had NO bearing on the pack pipeline; it must not acquire one now.
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  mkdirSync(join(fx.root, "gitnexus"), { recursive: true });
  writeFileSync(fx.registryPath, "{ this is not json");

  const summary = await run(baseOpts(fx));

  // the sweep SURVIVED, and everything the pack pipeline owes still happened
  expect(summary.failed).toEqual([]);
  expect(summary.succeeded).toContain("acme/widget");
  expect(existsSync(join(fx.brainRoot, "acme/widget.xml"))).toBe(true);
  const tree = await $`git -C ${fx.bare} ls-tree -r --name-only ${"automation/repomix-pack"}`.text();
  expect(tree).toContain(".llm/repomix.xml");

  // ...and the prune failure is recorded, reported, and not exit 0
  expect(summary.graph.pruneFailed).toMatch(/corrupt/i);
  expect(formatSummary(summary)).toMatch(/prune FAILED/i);
  expect(graphFailed(summary)).toBe(true);
  // a registry we cannot parse is never rewritten -- least of all emptied
  expect(readFileSync(fx.registryPath, "utf8")).toBe("{ this is not json");
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

test("a Slack failure costs the notification, never the repo or its PR", async () => {
  const fx = await makeFixture();
  writeMockGitnexus(fx);
  // Set up an adoption, so the sweep posts to Slack from INSIDE the per-repo try,
  // before the publish stage.
  const devClone = join(fx.devRoot, "widget");
  const orphaned = join(devClone, ".gitnexus");
  mkdirSync(orphaned, { recursive: true });
  writeFileSync(join(orphaned, "lbug"), "x".repeat(2048));
  seedRegistry(fx, [{ name: "widget", path: devClone, storagePath: orphaned }]);

  const summary = await run({
    ...baseOpts(fx),
    noNotify: false,
    webhook: "https://example.invalid/hook",
    // exactly what a bare `await fetch()` does on a DNS/connection blip
    postSlack: async () => {
      throw new Error("getaddrinfo ENOTFOUND hooks.slack.com");
    },
  });

  expect(summary.failed).toEqual([]); // the REPO did not fail
  expect(summary.succeeded).toContain("acme/widget");
  expect(summary.graph.analyzed).toContain("acme/widget");
  expect(summary.graph.adoptions).toHaveLength(1); // the disclosure still lands in the summary
  // ...and the publish stage that FOLLOWS the post still ran: the pack reached
  // the automation branch. A notification outage must never cost a repo its PR.
  const tree = await $`git -C ${fx.bare} ls-tree -r --name-only ${"automation/repomix-pack"}`.text();
  expect(tree).toContain(".llm/repomix.xml");
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
  // (no PR assertion here: baseOpts sets noPr, so `prs` could never be populated
  // and asserting on it would be vacuous. The Slack half is the real invariant.)
  expect(posted).toEqual([]);
});
