import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

export interface RegistryEntry {
  name: string;
  path: string;
  storagePath: string;
  lastCommit?: string;
  remoteUrl?: string;
  indexedAt?: string;
  stats?: Record<string, number>;
  // gitnexus owns this file; fields we don't model (e.g. branch, branches)
  // must survive a read -> mutate -> write round trip untouched.
  [key: string]: unknown;
}

export const DEFAULT_REGISTRY_PATH = join(homedir(), ".gitnexus", "registry.json");

export async function readRegistry(
  registryPath: string = DEFAULT_REGISTRY_PATH,
): Promise<RegistryEntry[]> {
  let raw: string;
  try {
    raw = await readFile(registryPath, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw err;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (cause) {
    throw new Error(
      `registry at ${registryPath} is corrupt (invalid JSON) -- refusing to touch it: ${(cause as Error).message}`,
      { cause: cause as Error },
    );
  }
  if (!Array.isArray(parsed)) {
    throw new Error(
      `registry at ${registryPath} is corrupt: expected a JSON array, got ${typeof parsed}`,
    );
  }
  return parsed as RegistryEntry[];
}

async function writeRegistryAtomic(
  registryPath: string,
  entries: RegistryEntry[],
  testDelayBeforeRenameMs?: number,
): Promise<void> {
  const dir = dirname(registryPath);
  await mkdir(dir, { recursive: true });
  const tmpPath = join(dir, `.registry.${randomBytes(6).toString("hex")}.tmp`);
  await writeFile(tmpPath, JSON.stringify(entries, null, 2));
  if (testDelayBeforeRenameMs) {
    await new Promise((r) => setTimeout(r, testDelayBeforeRenameMs));
  }
  // rename(2) is atomic on the same filesystem: readers/killers can never
  // observe a partially-written registry.json.
  await rename(tmpPath, registryPath);
}

const LOCK_RETRY_MS = 25;
const LOCK_TIMEOUT_MS = 10_000;

async function acquireLock(lockPath: string): Promise<void> {
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  for (;;) {
    try {
      const handle = await open(lockPath, "wx");
      await handle.close();
      return;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      if (Date.now() > deadline) {
        throw new Error(`timed out waiting for registry lock at ${lockPath}`);
      }
      await new Promise((r) => setTimeout(r, LOCK_RETRY_MS));
    }
  }
}

async function releaseLock(lockPath: string): Promise<void> {
  await rm(lockPath, { force: true });
}

export interface UpdateRegistryOpts {
  /** Test-only hook: pause after the temp file is written, before rename(2). */
  testDelayBeforeRenameMs?: number;
}

/** Mutate under an exclusive lock; writes via temp-file + rename(2). */
export async function updateRegistry(
  fn: (entries: RegistryEntry[]) => RegistryEntry[],
  registryPath: string = DEFAULT_REGISTRY_PATH,
  opts: UpdateRegistryOpts = {},
): Promise<void> {
  await mkdir(dirname(registryPath), { recursive: true });
  const lockPath = `${registryPath}.lock`;
  await acquireLock(lockPath);
  try {
    const current = await readRegistry(registryPath);
    const next = fn(current);
    await writeRegistryAtomic(registryPath, next, opts.testDelayBeforeRenameMs);
  } finally {
    await releaseLock(lockPath);
  }
}
