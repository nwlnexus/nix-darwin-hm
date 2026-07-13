import { loadTargets } from "./config";
import { checkout } from "./checkout";
import { runPack, packChanged } from "./pack";
import { ensureTracked } from "./gitignore";
import { commitToBranch, openOrUpdatePr } from "./git-pr";
import { StagingSink, RepoMeta } from "./sink";
import {
  buildSlackPayload,
  buildAdoptionPayload,
  formatAdoption,
  humanBytes,
  resolveWebhook,
  notifySlack,
  type Adoption,
} from "./notify";
import { refreshGraph, dirBytes, isAtOrUnder } from "./graph";
import { readRegistry, updateRegistry, DEFAULT_REGISTRY_PATH } from "./registry";
import { RepoTarget } from "./types";
import { existsSync } from "node:fs";
import { readdir, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface GraphSummary {
  analyzed: string[];
  skipped: string[];
  failed: { slug: string; error: string }[];
  /** Lossy first-sweep adoptions. MUST be surfaced -- see formatAdoption. */
  adoptions: Adoption[];
  /** `owner/name` of graphs dropped because the repo left repos.toml. */
  prunedGraphs: string[];
  /** Total on-disk size of every graph in the pipeline cache, post-sweep. */
  cacheBytes: number;
}

export interface RunSummary {
  succeeded: string[];
  skipped: string[];
  failed: { slug: string; error: string }[];
  prs: { slug: string; url: string }[];
  graph: GraphSummary;
}

export interface RunOpts {
  tomlPath: string;
  configPath: string;
  cacheRoot: string;
  brainRoot: string;
  group?: string;
  only?: string[];
  dryRun?: boolean;
  noPr?: boolean;
  brainOnly?: boolean;
  noNotify?: boolean;
  /** Skip the graph stage entirely (phase-1 behaviour). */
  noGraph?: boolean;
  /** Refresh graphs only; skip packing. */
  graphOnly?: boolean;
  originOverride?: Record<string, string>;
  concurrency?: number;
  /** Injectable so tests never touch the real ~/.gitnexus/registry.json. */
  registryPath?: string;
  /** Injectable so tests mock the binary instead of running a real analyze. */
  gitnexusBin?: string;
  /** Injectable so tests never resolve (or hit) the real webhook. */
  webhook?: string;
  postSlack?: (webhook: string, payload: object) => Promise<void>;
}

/**
 * Run `fn`s one at a time, in submission order, no matter how many callers are
 * in flight.
 *
 * The pack stage keeps its bounded parallel pool -- repomix is cheap and IO
 * bound. `gitnexus analyze` is not: it spawns its OWN worker pool sized to
 * cores-1, so N concurrent analyses oversubscribe the machine by a factor of N.
 * The graph stage is therefore serialized *specifically*, inside the parallel
 * worker, which keeps each repo's own order intact (checkout -> pack -> graph ->
 * PR) while allowing only one analyze at a time across the sweep.
 */
function serializer(): <T>(fn: () => Promise<T>) => Promise<T> {
  let tail: Promise<unknown> = Promise.resolve();
  return <T>(fn: () => Promise<T>): Promise<T> => {
    const next = tail.then(fn, fn);
    tail = next.then(
      () => {},
      () => {},
    );
    return next;
  };
}

interface GraphStorage {
  owner: string;
  name: string;
  path: string;
}

/** Every `<cacheRoot>/<owner>/<name>/.gitnexus` that exists right now. */
async function listGraphStorages(cacheRoot: string): Promise<GraphStorage[]> {
  const out: GraphStorage[] = [];
  let owners;
  try {
    owners = await readdir(cacheRoot, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const o of owners) {
    if (!o.isDirectory()) continue;
    let repos;
    try {
      repos = await readdir(join(cacheRoot, o.name), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const r of repos) {
      if (!r.isDirectory()) continue;
      const path = join(cacheRoot, o.name, r.name, ".gitnexus");
      if (!existsSync(path)) continue;
      out.push({ owner: o.name, name: r.name, path });
    }
  }
  return out;
}

async function graphCacheBytes(cacheRoot: string): Promise<number> {
  let total = 0;
  for (const s of await listGraphStorages(cacheRoot)) total += await dirBytes(s.path);
  return total;
}

/**
 * Drop graphs + registry entries for repos that are no longer in repos.toml.
 *
 * Two guards on the delete, because this is destructive:
 *  - the path must be at or under the pipeline's cache root, and
 *  - it must not be under ~/projects (a dev clone's own index is the user's,
 *    never ours to delete -- the same invariant graph.ts holds).
 *
 * The registry side only ever drops entries whose storage lives in OUR cache
 * tree. The user's own entries (the ones pointing at their own indexes) are
 * invisible to this function, and their storage is never touched. All registry
 * mutation goes through updateRegistry -- locked, atomic, field-preserving.
 *
 * `all` MUST be the UNFILTERED target list. Pruning against a --group/--only
 * subset would delete the graphs of every repo the sweep merely wasn't asked to
 * visit.
 */
async function pruneGraphs(
  cacheRoot: string,
  all: RepoTarget[],
  registryPath: string,
): Promise<string[]> {
  const keepDirs = new Set(all.map((t) => `${t.owner}/${t.name}`));
  const keepAliases = new Set(all.map((t) => t.name));
  const projectsRoot = join(homedir(), "projects");
  const pruned: string[] = [];

  for (const s of await listGraphStorages(cacheRoot)) {
    const key = `${s.owner}/${s.name}`;
    if (keepDirs.has(key)) continue;
    if (!isAtOrUnder(s.path, cacheRoot)) continue; // must be OUR cache tree
    if (isAtOrUnder(s.path, projectsRoot)) continue; // never a dev clone
    if (!s.path.endsWith("/.gitnexus")) continue;
    try {
      await rm(s.path, { recursive: true, force: true });
      pruned.push(key);
    } catch {
      // best effort: a stale graph costs disk, not correctness
    }
  }

  const entries = await readRegistry(registryPath);
  const stale = entries.filter((e) => {
    const sp = typeof e.storagePath === "string" ? e.storagePath : "";
    if (!sp || !isAtOrUnder(sp, cacheRoot)) return false; // not ours -> never touch
    return !keepAliases.has(e.name);
  });
  if (stale.length) {
    const drop = new Set(stale.map((e) => e.name));
    await updateRegistry((current) => current.filter((e) => !drop.has(e.name)), registryPath);
  }
  return pruned;
}

export async function run(opts: RunOpts): Promise<RunSummary> {
  if (opts.graphOnly && opts.noGraph) {
    throw new Error("--graph-only and --no-graph are mutually exclusive");
  }
  const targets = loadTargets(opts.tomlPath, { group: opts.group, only: opts.only });
  const registryPath = opts.registryPath ?? DEFAULT_REGISTRY_PATH;
  const post = opts.postSlack ?? notifySlack;
  const sink = new StagingSink(opts.brainRoot);
  const webhook = opts.noNotify ? "" : (opts.webhook ?? (await resolveWebhook()));
  const summary: RunSummary = {
    succeeded: [],
    skipped: [],
    failed: [],
    prs: [],
    graph: {
      analyzed: [],
      skipped: [],
      failed: [],
      adoptions: [],
      prunedGraphs: [],
      cacheBytes: 0,
    },
  };
  const limit = opts.concurrency ?? 4;

  // A dry run must not analyze, must not write the registry, and must not
  // delete anything -- so the prune, which does two of those three, is off too.
  const graphEnabled = !opts.noGraph && !opts.dryRun;

  if (graphEnabled) {
    // Prune against the UNFILTERED toml: --group/--only narrow the sweep, not
    // the set of repos the user still wants graphs for.
    summary.graph.prunedGraphs = await pruneGraphs(
      opts.cacheRoot,
      loadTargets(opts.tomlPath),
      registryPath,
    );
  }

  const serial = serializer();
  const queue = [...targets];
  async function worker() {
    for (let t = queue.shift(); t; t = queue.shift()) {
      try {
        if (opts.originOverride?.[t.slug]) t.originUrl = opts.originOverride[t.slug];
        const { dir, defaultBranch, headSha } = await checkout(t, opts.cacheRoot);

        let gate = { changed: false, bytes: 0, newHash: "" };
        if (!opts.graphOnly) {
          await runPack(dir, opts.configPath);
          // `gate` still tells us whether the pack itself changed, which drives
          // the brain-staging sink and the PR body's byte count. It is NOT the
          // PR gate anymore -- see commitToBranch, which gates on any staged
          // diff against base (pack, .gitignore, CLAUDE.md, AGENTS.md), so a
          // graph-only refresh (pack unchanged) still produces a PR.
          gate = await packChanged(dir, t.packPath);

          if (gate.changed) {
            const packBytes = new Uint8Array(
              await Bun.file(join(dir, t.packPath)).arrayBuffer(),
            );
            const meta: RepoMeta = {
              slug: t.slug, owner: t.owner, name: t.name, commit: headSha,
              hash: gate.newHash, bytes: gate.bytes, ts: new Date().toISOString(),
            };
            await sink.write(packBytes, meta);
          }
        }

        // --- graph stage -----------------------------------------------------
        // AFTER checkout (it analyzes the checkout) and BEFORE the PR step (so
        // any CLAUDE.md/AGENTS.md it rewrites is caught by commitToBranch's
        // "any staged diff" gate). SERIAL: one analyze at a time, machine-wide.
        //
        // `t.graph` is the per-repo opt-out. refreshGraph self-guards on it too,
        // but the caller gates as well -- belt and braces, because the failure
        // path of the graph stage touches the registry.
        if (graphEnabled && t.graph) {
          const g = await serial(() =>
            refreshGraph(t, dir, {
              registryPath,
              gitnexusBin: opts.gitnexusBin,
              // Must match index.ts's real cache root: it is the containment
              // guard on the only rm -rf in graph.ts. Never let these drift.
              cacheRoot: opts.cacheRoot,
            }),
          );
          if (g.status === "analyzed") summary.graph.analyzed.push(t.slug);
          else if (g.status === "failed") {
            // Per-repo isolation: a graph failure costs the graph, never the sweep.
            summary.graph.failed.push({ slug: t.slug, error: g.error ?? "unknown" });
          } else summary.graph.skipped.push(t.slug);

          if (g.adopted) {
            const adoption: Adoption = {
              slug: t.slug,
              droppedBranches: g.adopted.droppedBranches,
              orphanedStorage: g.adopted.orphanedStorage,
              bytes: await dirBytes(g.adopted.orphanedStorage),
            };
            summary.graph.adoptions.push(adoption);
            // Loud on purpose. This permanently dropped registrations and left
            // hundreds of MB orphaned; the user must not find out by accident.
            console.warn(`WARN ${formatAdoption(adoption)}`);
            await post(webhook, buildAdoptionPayload(adoption));
          }
        } else {
          summary.graph.skipped.push(t.slug);
        }

        // --- PR --------------------------------------------------------------
        let committed = false;
        if (!opts.brainOnly && !opts.dryRun) {
          const files = [".gitignore", "CLAUDE.md", "AGENTS.md"];
          if (!opts.graphOnly) {
            await ensureTracked(dir, t.packPath);
            files.unshift(t.packPath);
          }
          const result = await commitToBranch(dir, t, defaultBranch, files);
          committed = result.committed;
          if (committed && !opts.noPr) {
            const pr = await openOrUpdatePr(
              t, defaultBranch, "chore: refresh repomix context pack",
              `Automated repomix context pack refresh.\n\nCloses the paired tracking sub-issue.\nPack: \`${t.packPath}\` (${gate.bytes} bytes).`,
            );
            summary.prs.push({ slug: t.slug, url: pr.url });
            await post(webhook, buildSlackPayload({
              slug: t.slug, base: defaultBranch, prUrl: pr.url,
              created: pr.created, bytes: gate.bytes,
            }));
          }
        }

        if (!gate.changed && !committed) {
          summary.skipped.push(t.slug);
        } else {
          summary.succeeded.push(t.slug);
        }
      } catch (e) {
        summary.failed.push({ slug: t.slug, error: String(e) });
      }
    }
  }
  await Promise.all(Array.from({ length: limit }, worker));

  summary.graph.cacheBytes = await graphCacheBytes(opts.cacheRoot);
  return summary;
}

/** The end-of-run table: one row per repo, pack + graph, then the disk budget. */
export function formatSummary(s: RunSummary): string {
  const packOf = new Map<string, string>();
  for (const slug of s.succeeded) packOf.set(slug, "packed");
  for (const slug of s.skipped) packOf.set(slug, "skipped");
  for (const f of s.failed) packOf.set(f.slug, "failed");

  const graphOf = new Map<string, string>();
  for (const slug of s.graph.analyzed) graphOf.set(slug, "analyzed");
  for (const slug of s.graph.skipped) graphOf.set(slug, "skipped");
  for (const f of s.graph.failed) graphOf.set(f.slug, "failed");

  const slugs = [...new Set([...packOf.keys(), ...graphOf.keys()])].sort();
  const w = Math.max(4, ...slugs.map((x) => x.length));
  const lines = [
    `${"repo".padEnd(w)}  ${"pack".padEnd(8)}  graph`,
    `${"-".repeat(w)}  ${"-".repeat(8)}  ${"-".repeat(8)}`,
  ];
  for (const slug of slugs) {
    lines.push(
      `${slug.padEnd(w)}  ${(packOf.get(slug) ?? "-").padEnd(8)}  ${graphOf.get(slug) ?? "-"}`,
    );
  }

  lines.push("");
  lines.push(`graph cache: ${humanBytes(s.graph.cacheBytes)}`);
  if (s.graph.prunedGraphs.length) {
    lines.push(`pruned graphs (repo left repos.toml): ${s.graph.prunedGraphs.join(", ")}`);
  }
  for (const f of s.graph.failed) lines.push(`graph FAILED ${f.slug}: ${f.error}`);
  // Never let an adoption pass silently: it is lossy and it left disk behind.
  for (const a of s.graph.adoptions) lines.push(`WARN ${formatAdoption(a)}`);
  for (const p of s.prs) lines.push(`PR ${p.slug}: ${p.url}`);
  return lines.join("\n");
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const has = (f: string) => args.includes(f);
  const val = (f: string) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
  const home = process.env.HOME!;
  const groupArg = val("--group");
  const group = groupArg === "all" ? undefined : groupArg;
  const summary = await run({
    tomlPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repos.toml`,
    configPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repomix.config.json`,
    cacheRoot: `${home}/.cache/repomix-pipeline`,
    brainRoot: `${home}/.cache/repomix-pipeline/brain-staging`,
    group,
    only: has("--only") ? args.slice(args.indexOf("--only") + 1).filter((a) => a.includes("/")) : undefined,
    dryRun: has("--dry-run"), noPr: has("--no-pr"),
    brainOnly: has("--brain-only"), noNotify: has("--no-notify"),
    noGraph: has("--no-graph"), graphOnly: has("--graph-only"),
  });
  console.log(formatSummary(summary));
  console.log(JSON.stringify(summary, null, 2));
  if (summary.failed.length) process.exit(1);
}
