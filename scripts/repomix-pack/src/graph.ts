import { $ } from "bun";
import { existsSync } from "node:fs";
import { mkdir, readdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { randomBytes } from "node:crypto";
import { RepoTarget } from "./types";
import { DEFAULT_REGISTRY_PATH, readRegistry, updateRegistry } from "./registry";

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

/**
 * gitnexus has written full SHAs in every entry we've seen, but its own docs
 * show short SHAs. Treat a prefix match as the same commit so a short-SHA entry
 * doesn't force a pointless 14s+ re-analyze.
 */
function sameCommit(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  const x = a.trim().toLowerCase();
  const y = b.trim().toLowerCase();
  if (x.length < 7 || y.length < 7) return false;
  const n = Math.min(x.length, y.length);
  return x.slice(0, n) === y.slice(0, n);
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

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
  const tmpPath = join(dirname(path), `.${randomBytes(6).toString("hex")}.tmp`);
  await writeFile(tmpPath, JSON.stringify(value, null, 2));
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
  const metaPath = join(storageDir(cachePath), "meta.json");
  if (!existsSync(metaPath)) return undefined;
  try {
    const meta = JSON.parse(await readFile(metaPath, "utf8"));
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

/** Drop the entry so a half-written LadybugDB is never left registered. */
async function deregister(alias: string, registryPath: string): Promise<void> {
  await updateRegistry(
    (entries) => entries.filter((e) => e.name !== alias),
    registryPath,
  );
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

  try {
    // --- Step 1: commit gate -------------------------------------------------
    const head = await cacheHead(cachePath);
    const before = await readRegistry(registryPath);
    const existing = before.find((e) => e.name === alias);
    if (existing && sameCommit(existing.lastCommit, head)) {
      return { status: "skipped" };
    }

    // --- Step 2: analyze -----------------------------------------------------
    // NEVER cwd into cachePath: it carries the repo's own mise.toml and the
    // mise shim dies on untrusted config dirs. Neutral cwd, checkout as ARG.
    await mkdir(neutralCwd, { recursive: true });
    const run = await runAnalyze(bin, alias, cachePath, neutralCwd, timeoutMs);

    // --- Step 4: failure handling -------------------------------------------
    if (!run.ok) {
      // A corrupt-but-registered graph is worse than no graph.
      try {
        await deregister(alias, registryPath);
      } catch (e) {
        return {
          status: "failed",
          error: `${run.error} (and deregistration failed: ${String(e)})`,
        };
      }
      return { status: "failed", error: run.error };
    }

    // --- Step 3: re-anchor ---------------------------------------------------
    const storagePath = storageDir(cachePath);
    const nodes = await readNodeCount(cachePath);
    const bytes = await dirBytes(storagePath);

    // If the dev clone isn't on this machine, leave the entry anchored at the
    // cache. Not an error: the graph stays queryable, only the working-tree
    // tools are moot.
    if (existsSync(target.devClonePath)) {
      await updateRegistry((entries) => {
        const idx = entries.findIndex((e) => e.name === alias);
        if (idx === -1) {
          // analyze should have registered it; upsert so we never silently
          // leave the graph unregistered.
          return [
            ...entries,
            { name: alias, path: target.devClonePath, storagePath },
          ];
        }
        const next = [...entries];
        // Spread preserves branch/branches and anything else gitnexus owns.
        next[idx] = { ...next[idx], path: target.devClonePath, storagePath };
        return next;
      }, registryPath);

      await rewriteRepoPath(join(storagePath, "meta.json"), target.devClonePath);
      await rewriteRepoPath(join(storagePath, "gitnexus.json"), target.devClonePath);
    }

    return { status: "analyzed", nodes, bytes };
  } catch (e) {
    // Hard invariant: never throw into the sweep.
    return { status: "failed", error: String(e) };
  }
}
