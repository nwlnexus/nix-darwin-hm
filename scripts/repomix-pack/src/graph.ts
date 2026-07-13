import { $ } from "bun";
import { existsSync } from "node:fs";
import { chmod, mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { randomBytes } from "node:crypto";
import { RepoTarget } from "./types";
import {
  DEFAULT_REGISTRY_PATH,
  readRegistry,
  updateRegistry,
  type RegistryEntry,
} from "./registry";

export interface GraphResult {
  status: "analyzed" | "skipped" | "failed";
  nodes?: number;
  bytes?: number;
  error?: string;
  /**
   * Set only when this run ADOPTED a pre-existing entry that was not ours (its
   * storage lived somewhere else, typically the dev clone's own index).
   *
   * Adoption is LOSSY and the loss is permanent on the success path: the old
   * entry is dropped so the alias is free, gitnexus then creates a FRESH entry,
   * and any `branches` (multi-branch index registrations) the old entry carried
   * are gone. Carrying them forward would be worse, not better: they describe
   * branch storage under the OLD storagePath, and after adoption the entry's
   * storage is the cache, whose `branches/` is empty -- gitnexus would believe
   * in branch indexes that do not exist. Dropping them is the only coherent
   * option, so the only thing left to do is SAY SO. The sweep surfaces this.
   *
   * (On the FAILURE path rollbackFailedAnalyze restores the entry byte-for-byte,
   * branches included, so nothing is lost and this field is not reported.)
   */
  adopted?: {
    /** How many `branches` registrations the dropped entry carried. */
    droppedBranches: number;
    /** The old storagePath, now orphaned on disk (we never delete it). */
    orphanedStorage: string;
  };
}

export interface GraphOpts {
  /** Injectable so tests never touch the real ~/.gitnexus/registry.json. */
  registryPath?: string;
  /** Injectable so tests don't depend on this machine's mise install. */
  gitnexusBin?: string;
  /**
   * The pipeline's cache root (`~/.cache/repomix-pipeline`). This is the
   * POSITIVE containment guard on the module's only `rm -rf`: nothing outside
   * this tree is ever deletable, whatever `cachePath` a caller hands us.
   * Injectable so tests can point it at a temp dir.
   */
  cacheRoot?: string;
  /**
   * Where to invoke gitnexus FROM. Must never be the cache checkout: the
   * checkout carries the target repo's own mise.toml, and the mise shim
   * refuses to run in an untrusted config dir ("Config files in ... are not
   * trusted"). Verified: gitnexus does not chdir into the path argument, so a
   * neutral cwd is sufficient.
   */
  neutralCwd?: string;
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 15 * 60_000;

/** Mirrors index.ts's `cacheRoot`. Every deletable path lives under this tree. */
const DEFAULT_CACHE_ROOT = join(homedir(), ".cache", "repomix-pipeline");

/** Storage always stays in the cache, even after the entry is re-anchored. */
function storageDir(cachePath: string): string {
  return join(cachePath, ".gitnexus");
}

/** The manifest gitnexus writes on a successful analyze; its presence is our
 * proof that the cache storage actually exists on disk. */
function metaPath(cachePath: string): string {
  return join(storageDir(cachePath), "meta.json");
}

/** Lexical containment: is `child` the same path as, or under, `parent`? */
export function isAtOrUnder(child: string, parent: string): boolean {
  const rel = relative(resolve(parent), resolve(child));
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/**
 * Delete the CACHE's gitnexus storage so the next analyze starts clean.
 *
 * Why this has to exist (verified against gitnexus 1.6.9): storage that no
 * registry entry vouches for is poison. Hand gitnexus a cache that already has
 * a `.gitnexus` dir it did not just register and analyze dies with
 * "Analysis did not finalize ... the on-disk index is incomplete and was not
 * registered", every single time. One aborted analyze would otherwise wedge
 * that repo's graph forever -- a self-perpetuating failure, which is precisely
 * what a scheduled sweep must never have.
 *
 * Three hard guards, because this is the only rm in the module:
 *  - POSITIVE containment: the target must be at or under the pipeline's cache
 *    root. This is the one that holds when the others are vacuous -- the
 *    `.gitnexus` check is trivially true (storageDir always appends it) and the
 *    dev-clone check only catches THIS target's clone. A wiring bug handing us
 *    someone else's `cachePath` -- another repo under ~/projects, say -- would
 *    sail past both and rm -rf that repo's real index. Nothing outside the tree
 *    this pipeline created is deletable, full stop.
 *  - the path must be a `.gitnexus` dir, and
 *  - it must NOT be at or under the dev clone. Writing anything under
 *    ~/projects/** is a hard invariant; deleting the user's real index there
 *    would be unrecoverable. (`gitnexus remove`/`clean` are off-limits for the
 *    same reason: both delete the index on disk.)
 *
 * Never throws: losing the self-heal must not cost us the sweep. A refusal is
 * silent for the same reason -- the caller is always already on a path that
 * reports the underlying analyze error.
 */
async function clearCacheStorage(
  cachePath: string,
  devClonePath: string,
  cacheRoot: string,
): Promise<void> {
  const dir = storageDir(cachePath);
  if (!isAtOrUnder(dir, cacheRoot)) return; // must be OUR cache tree
  if (!dir.endsWith(`${"/"}.gitnexus`)) return;
  if (isAtOrUnder(dir, devClonePath)) return; // never touch the dev clone
  try {
    await rm(dir, { recursive: true, force: true });
  } catch {
    // best-effort; the failure path still reports the underlying analyze error
  }
}

/**
 * Plain equality. Every entry gitnexus writes carries a full 40-char SHA, so a
 * prefix-tolerant compare solves a non-problem and the cost asymmetry is wrong:
 * a false miss costs one re-analyze, a false skip silently serves a stale graph
 * forever.
 */
function sameCommit(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

/** HEAD of the cache checkout, which checkout() has reset --hard to origin. */
async function cacheHead(cachePath: string): Promise<string> {
  const res = await $`git -C ${cachePath} rev-parse HEAD`.quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(
      `git rev-parse HEAD failed in ${cachePath} (${res.exitCode}): ${res.stderr.toString()}`,
    );
  }
  return res.stdout.toString().trim();
}

/**
 * rename(2) replaces the target inode, so the temp file's mode becomes the
 * manifest's mode. Real meta.json/gitnexus.json are 0600 and carry fileHashes
 * and full path listings -- a default-mode temp file would silently widen them
 * to 0644.
 */
async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
  const tmpPath = join(dirname(path), `.${randomBytes(6).toString("hex")}.tmp`);
  await writeFile(tmpPath, JSON.stringify(value, null, 2), { mode: 0o600 });
  await chmod(tmpPath, 0o600); // umask can't widen it, but be explicit
  await rename(tmpPath, path);
}

/**
 * Point a storage manifest at `repoPath`, preserving every other field —
 * these files are gitnexus's, and carry stats/fileHashes/capabilities we
 * must not clobber. Missing files are tolerated: not every gitnexus version
 * necessarily writes both.
 */
async function rewriteRepoPath(
  manifestPath: string,
  repoPath: string,
): Promise<void> {
  if (!existsSync(manifestPath)) return;
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.repoPath = repoPath;
  await writeJsonAtomic(manifestPath, manifest);
}

async function readNodeCount(cachePath: string): Promise<number | undefined> {
  const p = metaPath(cachePath);
  if (!existsSync(p)) return undefined;
  try {
    const meta = JSON.parse(await readFile(p, "utf8"));
    const nodes = meta?.stats?.nodes;
    return typeof nodes === "number" ? nodes : undefined;
  } catch {
    return undefined;
  }
}

/** Recursive apparent size. Missing dirs are 0, not an error. */
export async function dirBytes(dir: string): Promise<number> {
  let total = 0;
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      total += await dirBytes(p);
    } else if (e.isFile()) {
      try {
        total += (await stat(p)).size;
      } catch {
        // raced with gitnexus's own cache churn; not worth failing over
      }
    }
  }
  return total;
}

/**
 * Undo whatever THIS run did to the registry after a failed analyze.
 *
 * Drop the entry only if this run could have corrupted the storage it points
 * at -- i.e. the pre-analyze entry already pointed at the storage dir we were
 * about to write (`<cachePath>/.gitnexus`), or there was no pre-analyze entry
 * at all (so anything present now was created by this run's analyze).
 *
 * A pre-existing entry pointing at DIFFERENT storage was never opened by this
 * run: a spawn failure (gitnexus is a mise shim and may not resolve on PATH
 * under launchd) must not delete a healthy entry and orphan its storage. It is
 * restored exactly as it was found.
 *
 * This is also what undoes preflightAlias: `existing` is the pre-preflight
 * snapshot, so an ADOPTed entry (not ours -> dropped) is put back byte-for-byte
 * including branch/branches, and a RECALLed entry (ours -> `path` moved to the
 * cache) is deregistered, which is the correct end state because the failure
 * path has just cleared the cache storage it described.
 */
async function rollbackFailedAnalyze(
  alias: string,
  existing: RegistryEntry | undefined,
  cachePath: string,
  registryPath: string,
): Promise<void> {
  const ours = !!existing && existing.storagePath === storageDir(cachePath);
  await updateRegistry((entries) => {
    if (existing && !ours) {
      const idx = entries.findIndex((e) => e.name === alias);
      if (idx === -1) return [...entries, existing];
      const next = [...entries];
      next[idx] = existing; // restore the untouched pre-existing entry
      return next;
    }
    return entries.filter((e) => e.name !== alias);
  }, registryPath);
}

/**
 * Make the alias analyzable. REGISTRY-ONLY (plus the cache's own storage).
 *
 * gitnexus REFUSES -- exit 1, "Registry name collision" -- to analyze under an
 * alias whose registry entry points at a path OTHER than the one being
 * analyzed. Our entries point at the dev clone by design while we analyze the
 * cache, so without this the graph never builds for an already-indexed repo
 * (the state all three of the user's real entries are in) and, once built,
 * would never refresh again. Verified against gitnexus 1.6.9: the check keys on
 * `path`, NOT on `storagePath`.
 *
 * `--allow-duplicate-name` is not an option: it leaves `-r <name>` ambiguous,
 * which breaks the name-based resolution this whole design rests on.
 *
 * Two shapes:
 *
 *  - ADOPT (the entry is not ours -- its storage is somewhere else, typically
 *    the dev clone's own index): drop the entry so the alias is free. The dev
 *    clone's storage BYTES ARE NEVER TOUCHED -- they are left orphaned on disk
 *    for the user to reclaim by hand. `gitnexus remove`/`clean` are off-limits
 *    precisely because both delete the index on disk.
 *
 *    Adoption is LOSSY: gitnexus creates a FRESH entry, so any `branches` the
 *    old one carried are gone for good on the success path. That cannot be
 *    fixed (see GraphResult.adopted), so it is REPORTED -- this function
 *    returns what the drop cost, and refreshGraph surfaces it on success.
 *
 *  - RECALL (the entry is ours -- storagePath already IS the cache -- but it is
 *    anchored at the dev clone, i.e. the steady state after any previous run):
 *    point `path` back at the cache just for the analyze. gitnexus then merges
 *    into the existing entry, which keeps the index incremental and lets the
 *    fields it owns (branch/branches) survive via its own merge. reanchor()
 *    moves `path` back onto the dev clone afterwards.
 *
 * The caller snapshots `existing` beforehand and rollbackFailedAnalyze restores
 * it byte-for-byte if the analyze then fails, so a failed preflight is a no-op
 * on the registry.
 */
async function preflightAlias(
  alias: string,
  existing: RegistryEntry | undefined,
  cachePath: string,
  devClonePath: string,
  registryPath: string,
  cacheRoot: string,
): Promise<GraphResult["adopted"]> {
  const ours = !!existing && existing.storagePath === storageDir(cachePath);

  // Cache storage that no registry entry vouches for is poison to the next
  // analyze (see clearCacheStorage). Clearing it here is what lets an adoption
  // -- and a sweep following an aborted analyze -- succeed on the FIRST try
  // rather than burning a run to heal.
  if (!ours) await clearCacheStorage(cachePath, devClonePath, cacheRoot);

  if (!existing) return undefined;

  await updateRegistry((entries) => {
    const idx = entries.findIndex((e) => e.name === alias);
    if (idx === -1) return entries;
    if (!ours) return entries.filter((e) => e.name !== alias); // ADOPT
    if (entries[idx].path === cachePath) return entries; // already analyzable
    const next = [...entries];
    next[idx] = { ...next[idx], path: cachePath }; // RECALL
    return next;
  }, registryPath);

  if (ours) return undefined;
  return {
    droppedBranches: Array.isArray(existing.branches) ? existing.branches.length : 0,
    orphanedStorage: existing.storagePath,
  };
}

/**
 * Point the entry + both storage manifests at the dev clone.
 *
 * Write order matters: the manifests go FIRST and `updateRegistry` LAST, as the
 * single commit point. A manifest write that throws then leaves a coherent,
 * fully-cache-anchored entry -- exactly the "dev clone missing" state we already
 * treat as fine -- instead of a half-anchored registry/manifest split.
 *
 * `storagePath` is deliberately NOT asserted: it is gitnexus's field and is
 * already correct post-analyze. Only `path` changes.
 */
async function reanchor(
  alias: string,
  devClonePath: string,
  storagePath: string,
  registryPath: string,
): Promise<void> {
  await rewriteRepoPath(join(storagePath, "meta.json"), devClonePath);
  await rewriteRepoPath(join(storagePath, "gitnexus.json"), devClonePath);

  await updateRegistry((entries) => {
    const idx = entries.findIndex((e) => e.name === alias);
    if (idx === -1) {
      // analyze should have registered it; upsert so we never silently leave
      // the graph unregistered.
      return [...entries, { name: alias, path: devClonePath, storagePath }];
    }
    const next = [...entries];
    // Spread preserves branch/branches and anything else gitnexus owns.
    next[idx] = { ...next[idx], path: devClonePath };
    return next;
  }, registryPath);
}

interface RunResult {
  ok: boolean;
  /**
   * Did the process actually start? A spawn failure (gitnexus is a mise shim
   * and may not resolve on PATH under launchd) means analyze NEVER RAN and the
   * cache storage on disk is exactly as the last good run left it -- healthy,
   * registered, and worth hundreds of MB and minutes of rebuild per repo. Only
   * a process that really ran can have left a partial/unregistered index, so
   * only then is the self-heal `rm` warranted. Otherwise one bad PATH would
   * nuke every repo's graph on every sweep.
   */
  spawned: boolean;
  error?: string;
}

async function runAnalyze(
  bin: string,
  alias: string,
  cachePath: string,
  cwd: string,
  timeoutMs: number,
): Promise<RunResult> {
  let proc;
  try {
    proc = Bun.spawn(
      [bin, "analyze", "--no-stats", "--skip-skills", "--name", alias, cachePath],
      { cwd, stdout: "pipe", stderr: "pipe" },
    );
  } catch (e) {
    // e.g. binary not found / not executable
    return {
      ok: false,
      spawned: false,
      error: `gitnexus could not be spawned: ${String(e)}`,
    };
  }

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill("SIGKILL");
  }, timeoutMs);

  let exitCode: number;
  try {
    exitCode = await proc.exited;
  } finally {
    clearTimeout(timer);
  }

  if (timedOut) {
    return {
      ok: false,
      spawned: true,
      error: `gitnexus analyze timed out after ${timeoutMs}ms`,
    };
  }
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    return {
      ok: false,
      spawned: true,
      error: `gitnexus analyze failed (${exitCode}): ${stderr.trim() || "(no stderr)"}`,
    };
  }
  return { ok: true, spawned: true };
}

/**
 * Refresh the gitnexus graph for `target` from its persistent cache checkout,
 * then re-anchor the registry entry at the user's dev clone.
 *
 * The graph is built in the cache (clean tree, correct default branch) but the
 * registry entry points at the dev clone, so gitnexus's working-tree tools
 * (`detect-changes`, `rename`) operate on the user's real repo while the graph
 * storage stays out of it.
 *
 * Never throws: per-repo isolation is a hard invariant of the sweep.
 */
export async function refreshGraph(
  target: RepoTarget,
  cachePath: string,
  opts: GraphOpts = {},
): Promise<GraphResult> {
  const registryPath = opts.registryPath ?? DEFAULT_REGISTRY_PATH;
  const cacheRoot = opts.cacheRoot ?? DEFAULT_CACHE_ROOT;
  const bin = opts.gitnexusBin ?? "gitnexus";
  const neutralCwd = opts.neutralCwd ?? tmpdir();
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const alias = target.name;
  const storagePath = storageDir(cachePath);

  // Defense in depth: the caller gates on this too, but a forgotten gate here
  // would let a failure path touch the registry entry of a repo the user
  // explicitly opted out of.
  if (!target.graph) return { status: "skipped" };

  try {
    // --- Step 1: commit gate -------------------------------------------------
    const head = await cacheHead(cachePath);
    const before = await readRegistry(registryPath);
    const existing = before.find((e) => e.name === alias);

    // The gate skips the ANALYZE, not the re-anchor. Guarding on the cache
    // storage actually existing closes two false skips at once:
    //  - storage pruned (user cleared the cache dir): no meta.json -> treat the
    //    gate as a MISS and rebuild, instead of skipping forever with a
    //    storagePath pointing at a deleted dir.
    //  - anchor drift: entry still anchored at the cache because the dev clone
    //    was absent on an earlier run. HEAD hasn't moved, so a plain gate hit
    //    would never re-anchor -- and gitnexus's `rename` would then write the
    //    user's refactor into the cache checkout, where checkout()'s
    //    `reset --hard` silently destroys it.
    if (
      existing &&
      sameCommit(existing.lastCommit, head) &&
      existsSync(metaPath(cachePath))
    ) {
      if (existsSync(target.devClonePath)) {
        await reanchor(alias, target.devClonePath, storagePath, registryPath);
      }
      return { status: "skipped" };
    }

    // --- Step 2: analyze -----------------------------------------------------
    // Free the alias first: gitnexus refuses to analyze under a name whose
    // entry points elsewhere, and every entry we own points at the dev clone.
    const adopted = await preflightAlias(
      alias,
      existing,
      cachePath,
      target.devClonePath,
      registryPath,
      cacheRoot,
    );

    // NEVER cwd into cachePath: it carries the repo's own mise.toml and the
    // mise shim dies on untrusted config dirs. Neutral cwd, checkout as ARG.
    await mkdir(neutralCwd, { recursive: true });
    const run = await runAnalyze(bin, alias, cachePath, neutralCwd, timeoutMs);

    // --- Step 4: failure handling -------------------------------------------
    if (!run.ok) {
      // Self-heal. An aborted analyze leaves an index that is on disk but
      // unregistered, and gitnexus refuses to analyze over one ("the on-disk
      // index is incomplete and was not registered" / a leftover lbug.wal), so
      // a single failure would wedge this repo's graph FOREVER -- every later
      // sweep failing the same way. Cache-only, never a dev clone.
      //
      // ONLY if the process actually ran. A spawn failure means analyze never
      // touched the storage, so there is nothing to heal and everything to lose
      // (see RunResult.spawned).
      if (run.spawned) {
        await clearCacheStorage(cachePath, target.devClonePath, cacheRoot);
      }
      // A corrupt-but-registered graph is worse than no graph -- but only OUR
      // storage can be corrupt. See rollbackFailedAnalyze.
      try {
        await rollbackFailedAnalyze(alias, existing, cachePath, registryPath);
      } catch (e) {
        return {
          status: "failed",
          error: `${run.error} (and registry rollback failed: ${String(e)})`,
        };
      }
      return { status: "failed", error: run.error };
    }

    // A "successful" analyze that left no meta.json means the storage is not
    // there. rewriteRepoPath tolerates missing manifests, so without this the
    // re-anchor would silently no-op and we'd report a graph that isn't built.
    if (!existsSync(metaPath(cachePath))) {
      const error = `gitnexus analyze reported success but wrote no ${metaPath(cachePath)}`;
      // The process did run here by definition, so the self-heal applies.
      await clearCacheStorage(cachePath, target.devClonePath, cacheRoot);
      try {
        await rollbackFailedAnalyze(alias, existing, cachePath, registryPath);
      } catch (e) {
        return { status: "failed", error: `${error} (and registry rollback failed: ${String(e)})` };
      }
      return { status: "failed", error };
    }

    // --- Step 3: re-anchor ---------------------------------------------------
    const nodes = await readNodeCount(cachePath);
    const bytes = await dirBytes(storagePath);

    // If the dev clone isn't on this machine, leave the entry anchored at the
    // cache. Not an error: the graph stays queryable, only the working-tree
    // tools are moot.
    if (existsSync(target.devClonePath)) {
      await reanchor(alias, target.devClonePath, storagePath, registryPath);
    }

    // `adopted` rides along on SUCCESS only: on failure the entry (branches and
    // all) was restored, so nothing was lost and there is nothing to report.
    return { status: "analyzed", nodes, bytes, ...(adopted ? { adopted } : {}) };
  } catch (e) {
    // Hard invariant: never throw into the sweep.
    return { status: "failed", error: String(e) };
  }
}
