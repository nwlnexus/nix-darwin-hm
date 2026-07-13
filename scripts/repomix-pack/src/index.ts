import { loadTargets } from "./config";
import { checkout } from "./checkout";
import { runPack, packChanged } from "./pack";
import { ensureTracked } from "./gitignore";
import { commitToBranch, openOrUpdatePr } from "./git-pr";
import { StagingSink, RepoMeta } from "./sink";
import {
  buildSlackPayload,
  buildAdoptionPayload,
  buildGraphFailurePayload,
  formatAdoption,
  humanBytes,
  resolveWebhook,
  notifySlack,
  type Adoption,
} from "./notify";
import { refreshGraph, dirBytes, isAtOrUnder, defaultGitnexusBin } from "./graph";
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
  /** `owner/name` of cache dirs (checkout + graph) dropped because the repo left repos.toml. */
  prunedGraphs: string[];
  /**
   * `owner/name` of repos still in repos.toml but opted OUT of graphing
   * (`graph = false`), whose stale `.gitnexus` + registry entry were dropped.
   * Their CHECKOUT stays: the pack stage still needs it every sweep.
   */
  prunedOptOuts: string[];
  /**
   * Why the prune stage failed, if it did (corrupt registry, lock timeout).
   * The prune is disk hygiene; it must never cost the sweep its packs -- so it
   * is caught, recorded HERE, and reported like any other graph failure.
   */
  pruneFailed?: string;
  /** Total on-disk size of every graph in the pipeline cache, post-sweep. */
  cacheBytes: number;
}

export interface RunSummary {
  succeeded: string[];
  skipped: string[];
  failed: { slug: string; error: string }[];
  prs: { slug: string; url: string }[];
  /**
   * True when the publish stage (commit -> force-push -> PR -> Slack) was
   * suppressed because the sweep ran with --graph-only. Surfaced so a sweep that
   * deliberately published nothing is never mistaken for one that had nothing to
   * publish. See the publish block in `run` for why --graph-only implies --no-pr.
   */
  publishSkipped: boolean;
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
  /**
   * Refresh graphs only; skip packing. IMPLIES `noPr`: the whole publish stage
   * (commit, force-push, PR, Slack) is skipped, because with no pack staged a
   * commit would rewrite the automation branch off base and strip a pending
   * pack out of an already-open PR.
   */
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

interface CacheRepo {
  owner: string;
  name: string;
  /** `<cacheRoot>/<owner>/<name>` -- the checkout. */
  path: string;
  /** `<cacheRoot>/<owner>/<name>/.gitnexus` -- the graph storage. */
  graphPath: string;
}

/**
 * Every `<cacheRoot>/<owner>/<name>` this pipeline created.
 *
 * "Created by us" means it carries one of our two markers -- a git checkout
 * (`.git`) or a graph storage (`.gitnexus`). Anything else under the cache root
 * is not ours to enumerate, let alone delete: in production `brainRoot` is
 * `<cacheRoot>/brain-staging`, whose `<owner>/` children have the same SHAPE as
 * a repo dir and none of the markers.
 */
async function listCacheRepos(cacheRoot: string): Promise<CacheRepo[]> {
  const out: CacheRepo[] = [];
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
      const path = join(cacheRoot, o.name, r.name);
      const graphPath = join(path, ".gitnexus");
      if (!existsSync(graphPath) && !existsSync(join(path, ".git"))) continue;
      out.push({ owner: o.name, name: r.name, path, graphPath });
    }
  }
  return out;
}

async function graphCacheBytes(cacheRoot: string): Promise<number> {
  let total = 0;
  for (const s of await listCacheRepos(cacheRoot)) total += await dirBytes(s.graphPath);
  return total;
}

/**
 * Drop the CACHE DIR (checkout + graph) and registry entries for repos that are
 * no longer in repos.toml.
 *
 * The whole `<cacheRoot>/<owner>/<name>` goes, not just its `.gitnexus`: the
 * checkout is the bulk of the disk (a full clone per repo) and, left behind, it
 * would linger forever with nothing in repos.toml to ever revisit it.
 *
 * Guards on the delete, because this is destructive:
 *  - the path must be STRICTLY under the pipeline's cache root (never the root
 *    itself),
 *  - it must not be at or under the brain-staging root (which in production
 *    lives INSIDE the cache root and holds the sweep's real output),
 *  - it must carry one of our markers (.git / .gitnexus -- see listCacheRepos),
 *  - it must not be under ~/projects (a dev clone is the user's, never ours to
 *    delete -- the same invariant graph.ts holds).
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
  brainRoot: string,
  all: RepoTarget[],
  registryPath: string,
): Promise<{ prunedGraphs: string[]; prunedOptOuts: string[] }> {
  // Two different keeps, because `graph = false` is not the same as "gone".
  //  - keepDirs: every repo still in repos.toml keeps its CHECKOUT, graph flag
  //    or not -- the pack stage clones into it on every single sweep, so
  //    deleting it would mean a full re-clone per sweep, forever.
  //  - keepGraphs: only repos still being GRAPHED keep their `.gitnexus` and
  //    their registry entry. A repo opted out AFTER it was graphed would
  //    otherwise keep both for good: a stale graph that nothing ever refreshes,
  //    and a registry entry pointing at it, which `gitnexus -r <name>` will
  //    happily serve as if it were current.
  const keepDirs = new Set(all.map((t) => `${t.owner}/${t.name}`));
  const graphed = all.filter((t) => t.graph);
  const keepGraphs = new Set(graphed.map((t) => `${t.owner}/${t.name}`));
  const keepAliases = new Set(graphed.map((t) => t.name));
  const projectsRoot = join(homedir(), "projects");
  const prunedGraphs: string[] = [];
  const prunedOptOuts: string[] = [];

  /** Every guard on the only rm -rf pair in this file. See the doc comment. */
  const deletable = (p: string): boolean =>
    isAtOrUnder(p, cacheRoot) && // must be OUR cache tree
    !isAtOrUnder(cacheRoot, p) && // ...and STRICTLY under it
    !isAtOrUnder(p, brainRoot) && // never the staged output
    !isAtOrUnder(p, projectsRoot); // never a dev clone

  for (const s of await listCacheRepos(cacheRoot)) {
    const key = `${s.owner}/${s.name}`;
    const target = keepDirs.has(key)
      ? keepGraphs.has(key)
        ? null // still graphed: nothing to prune
        : s.graphPath // opted out: drop the stale graph, KEEP the checkout
      : s.path; // gone from repos.toml: drop the whole cache dir
    if (!target) continue;
    if (!existsSync(target)) continue;
    if (!deletable(target)) continue;
    try {
      await rm(target, { recursive: true, force: true });
      (target === s.path ? prunedGraphs : prunedOptOuts).push(key);
    } catch {
      // best effort: a stale checkout costs disk, not correctness
    }
  }

  const entries = await readRegistry(registryPath);
  const stale = entries.filter((e) => {
    const sp = typeof e.storagePath === "string" ? e.storagePath : "";
    if (!sp || !isAtOrUnder(sp, cacheRoot)) return false; // not ours -> never touch
    return !keepAliases.has(e.name); // departed OR opted out
  });
  if (stale.length) {
    const drop = new Set(stale.map((e) => e.name));
    await updateRegistry((current) => current.filter((e) => !drop.has(e.name)), registryPath);
  }
  return { prunedGraphs, prunedOptOuts };
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
    publishSkipped: !!opts.graphOnly,
    graph: {
      analyzed: [],
      skipped: [],
      failed: [],
      adoptions: [],
      prunedGraphs: [],
      prunedOptOuts: [],
      cacheBytes: 0,
    },
  };
  const limit = opts.concurrency ?? 4;

  /**
   * A notification is a side effect of the sweep, NEVER a gate on it.
   *
   * `notifySlack` does a bare `await fetch(...)`, which REJECTS on a DNS or
   * connection failure. Called inside the per-repo `try`, one transient Slack
   * blip would throw into the outer catch: the repo lands in `summary.failed`,
   * its commit/PR is skipped entirely, and the CLI exits 1 -- a notification
   * outage costing a repo its pack PR. Everything a post carries is already in
   * the summary (which is printed regardless), so a failed post is worth a
   * warning and nothing more.
   */
  const safePost = async (payload: object, what: string): Promise<void> => {
    try {
      await post(webhook, payload);
    } catch (e) {
      console.warn(`WARN slack notify failed (${what}): ${String(e)}`);
    }
  };

  // A dry run must not analyze, must not write the registry, and must not
  // delete anything -- so the prune, which does two of those three, is off too.
  const graphEnabled = !opts.noGraph && !opts.dryRun;

  if (graphEnabled) {
    // ISOLATED, exactly like a per-repo failure. pruneGraphs reads and writes
    // the registry, so it throws on a corrupt registry.json and on a 10s lock
    // timeout -- and it runs BEFORE the pack stage. Unguarded, either one would
    // throw straight out of run() and take the whole sweep down, PACKS INCLUDED:
    // a wedged registry lock would cost 11 repos their context packs and their
    // PRs. Before the graph stage existed the registry had no bearing on the
    // pack pipeline whatsoever, and it must not acquire one now. The prune is
    // disk hygiene; its worst failure is disk left on disk.
    //
    // Prune against the UNFILTERED toml: --group/--only narrow the sweep, not
    // the set of repos the user still wants graphs for.
    try {
      const pruned = await pruneGraphs(
        opts.cacheRoot,
        opts.brainRoot,
        loadTargets(opts.tomlPath),
        registryPath,
      );
      summary.graph.prunedGraphs = pruned.prunedGraphs;
      summary.graph.prunedOptOuts = pruned.prunedOptOuts;
    } catch (e) {
      // Recorded, not swallowed: it lands in the summary, the exit code and Slack.
      summary.graph.pruneFailed = String(e);
    }
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
            await safePost(buildAdoptionPayload(adoption), `adoption ${t.slug}`);
          }
        } else {
          summary.graph.skipped.push(t.slug);
        }

        // --- publish (commit -> force-push -> PR -> Slack) ---------------------
        // --graph-only publishes NOTHING -- it implies --no-pr, and more: it
        // skips commitToBranch too. commitToBranch cuts the automation branch
        // fresh from `origin/<base>` and FORCE-pushes it. Under --graph-only the
        // pack was never regenerated and is not staged, so any staged diff at all
        // (gitnexus rewriting CLAUDE.md/AGENTS.md is exactly that) would rewrite
        // the branch to base + docs: a pack commit sitting in an OPEN, unmerged
        // PR is silently dropped from it, and the PR body is relabelled
        // "0 bytes" (gate.bytes never left 0). --graph-only refreshes graphs; it
        // does not touch anyone's pending PR. Reported via summary.publishSkipped.
        let committed = false;
        if (!opts.brainOnly && !opts.dryRun && !opts.graphOnly) {
          const files = [t.packPath, ".gitignore", "CLAUDE.md", "AGENTS.md"];
          await ensureTracked(dir, t.packPath);
          const result = await commitToBranch(dir, t, defaultBranch, files);
          committed = result.committed;
          if (committed && !opts.noPr) {
            const pr = await openOrUpdatePr(
              t, defaultBranch, "chore: refresh repomix context pack",
              `Automated repomix context pack refresh.\n\nCloses the paired tracking sub-issue.\nPack: \`${t.packPath}\` (${gate.bytes} bytes).`,
            );
            summary.prs.push({ slug: t.slug, url: pr.url });
            await safePost(buildSlackPayload({
              slug: t.slug, base: defaultBranch, prUrl: pr.url,
              created: pr.created, bytes: gate.bytes,
            }), `pr ${t.slug}`);
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

  // --- graph failures are LOUD ------------------------------------------------
  // Per-repo isolation means a graph failure costs the graph and nothing else --
  // not the sweep, not the repo's pack, not its PR. That is about CONTROL FLOW.
  // It must not also mean the failure is INVISIBLE: a graph stage that is broken
  // for every repo on every scheduled run (a binary that doesn't resolve under
  // launchd, say) otherwise looks exactly like a clean sweep -- exit 0, no
  // Slack, packs still flowing. The graphs quietly rot and nobody is told.
  //
  // So the failures get their own post, once per sweep (not per repo: a
  // systemic breakage would mean 11 identical messages), and they get the exit
  // code (see the CLI). Posted AFTER the workers, so it can never be on the
  // critical path of any repo's publish.
  if (graphFailed(summary)) {
    await safePost(buildGraphFailurePayload(summary.graph), "graph failures");
  }

  summary.graph.cacheBytes = await graphCacheBytes(opts.cacheRoot);
  return summary;
}

/**
 * Did the graph stage break? The single source of truth for "this sweep must not
 * exit 0", shared by the CLI exit code and the Slack post so the two can never
 * disagree about what counts as broken.
 *
 * Pack failures are tracked separately (`summary.failed`) and already gate the
 * exit code; this is the half that used to be silent.
 */
export function graphFailed(s: RunSummary): boolean {
  return s.graph.failed.length > 0 || !!s.graph.pruneFailed;
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
  if (s.publishSkipped) {
    lines.push(
      "--graph-only: publish stage skipped (implies --no-pr: no commit, no push, no PR, no Slack)",
    );
  }
  if (s.graph.prunedGraphs.length) {
    lines.push(`pruned cache dirs (repo left repos.toml): ${s.graph.prunedGraphs.join(", ")}`);
  }
  if (s.graph.prunedOptOuts.length) {
    lines.push(`pruned stale graphs (graph = false): ${s.graph.prunedOptOuts.join(", ")}`);
  }
  if (s.graph.pruneFailed) {
    lines.push(`graph prune FAILED (sweep continued): ${s.graph.pruneFailed}`);
  }
  for (const f of s.graph.failed) lines.push(`graph FAILED ${f.slug}: ${f.error}`);
  // Never let an adoption pass silently: it is lossy and it left disk behind.
  for (const a of s.graph.adoptions) lines.push(`WARN ${formatAdoption(a)}`);
  for (const p of s.prs) lines.push(`PR ${p.slug}: ${p.url}`);
  return lines.join("\n");
}

const USAGE = `repomix-pack -- refresh repomix context packs + gitnexus graphs

  --group <name|all>   only this repos.toml group (default: all)
  --only <slug>...     only these owner/name slugs
  --dry-run            no analyze, no registry write, no prune, no publish
  --no-pr              commit + push, but never open/update a PR
  --brain-only         stage the pack to the brain; never touch git
  --no-notify          never post to Slack
  --no-graph           skip the gitnexus graph stage entirely
  --graph-only         refresh graphs only; skip packing.
                       IMPLIES --no-pr, and publishes nothing at all: with no
                       pack staged, a commit would cut the automation branch
                       from base and force-push, stripping a pending pack out of
                       an already-open PR. Use a full sweep to publish.
  --help               this text
`;

if (import.meta.main) {
  const args = process.argv.slice(2);
  const has = (f: string) => args.includes(f);
  if (has("--help") || has("-h")) {
    console.log(USAGE);
    process.exit(0);
  }
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
    // ABSOLUTE path, resolved from HOME -- never a bare `gitnexus`. The binary is
    // a mise global whose shims dir is on PATH only inside an interactive shell;
    // the launchd agent has no such PATH, so a bare name is ENOENT on exactly the
    // runs that matter. See defaultGitnexusBin. (The launchd agent's PATH is
    // fixed too, in modules/repomix/repomix.nix -- `repomix` itself has the same
    // problem. Both, because either alone still leaves a broken scheduled sweep.)
    gitnexusBin: defaultGitnexusBin(home),
  });
  console.log(formatSummary(summary));
  console.log(JSON.stringify(summary, null, 2));
  // A broken graph stage must NEVER exit 0. It is not fatal to the sweep (the
  // packs shipped, per-repo isolation held) but it is not success either, and a
  // silent exit 0 is what let a permanently-failing graph stage pass for a clean
  // run. Slack gets the same news, from graphFailed, in run().
  if (summary.failed.length || graphFailed(summary)) process.exit(1);
}
