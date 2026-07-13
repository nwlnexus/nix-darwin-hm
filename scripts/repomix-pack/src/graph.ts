import { $ } from "bun";
import { existsSync } from "node:fs";
import { chmod, mkdir, readdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
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
}

export interface GraphOpts {
  /** Injectable so tests never touch the real ~/.gitnexus/registry.json. */
  registryPath?: string;
  /** Injectable so tests don't depend on this machine's mise install. */
  gitnexusBin?: string;
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

/** Storage always stays in the cache, even after the entry is re-anchored. */
function storageDir(cachePath: string): string {
  return join(cachePath, ".gitnexus");
}

/** The manifest gitnexus writes on a successful analyze; its presence is our
 * proof that the cache storage actually exists on disk. */
function metaPath(cachePath: string): string {
  return join(storageDir(cachePath), "meta.json");
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

async function dirBytes(dir: string): Promise<number> {
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
    return { ok: false, error: `gitnexus could not be spawned: ${String(e)}` };
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
      error: `gitnexus analyze timed out after ${timeoutMs}ms`,
    };
  }
  if (exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    return {
      ok: false,
      error: `gitnexus analyze failed (${exitCode}): ${stderr.trim() || "(no stderr)"}`,
    };
  }
  return { ok: true };
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
    // NEVER cwd into cachePath: it carries the repo's own mise.toml and the
    // mise shim dies on untrusted config dirs. Neutral cwd, checkout as ARG.
    await mkdir(neutralCwd, { recursive: true });
    const run = await runAnalyze(bin, alias, cachePath, neutralCwd, timeoutMs);

    // --- Step 4: failure handling -------------------------------------------
    if (!run.ok) {
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

    return { status: "analyzed", nodes, bytes };
  } catch (e) {
    // Hard invariant: never throw into the sweep.
    return { status: "failed", error: String(e) };
  }
}
