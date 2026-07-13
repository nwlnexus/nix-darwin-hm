import { test, expect } from "bun:test";
import { readRegistry, updateRegistry, type RegistryEntry } from "./registry";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

function fixtureDir(): string {
  return mkdtempSync(join(tmpdir(), "registry-"));
}

test("reads a well-formed registry", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "registry.json");
  const entries: RegistryEntry[] = [
    {
      name: "olympus-sdk",
      path: "/Users/x/projects/personal/olympus-sdk",
      storagePath: "/Users/x/projects/personal/olympus-sdk/.gitnexus",
      indexedAt: "2026-07-07T02:11:54.001Z",
      lastCommit: "5bae710",
      remoteUrl: "git@github.com:nwlnexus/olympus-sdk",
      stats: { files: 655, nodes: 10480, edges: 16318, communities: 220, processes: 300, embeddings: 0 },
    },
    {
      name: "moneta",
      path: "/Users/x/projects/personal/moneta",
      storagePath: "/Users/x/projects/personal/moneta/.gitnexus",
    },
  ];
  writeFileSync(registryPath, JSON.stringify(entries, null, 2));

  const result = await readRegistry(registryPath);
  expect(result).toEqual(entries);
});

test("missing registry file yields [] instead of throwing", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "does-not-exist.json");

  const result = await readRegistry(registryPath);
  expect(result).toEqual([]);
});

test("corrupt/truncated registry surfaces a clear error, never silently overwritten", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "registry.json");
  const truncated = '[{"name":"olympus-sdk","path":"/x","storagePath":"/x/.gitnex';
  writeFileSync(registryPath, truncated);

  await expect(readRegistry(registryPath)).rejects.toThrow();

  // updateRegistry must not overwrite a registry it cannot safely read.
  await expect(
    updateRegistry((entries) => [...entries, { name: "new", path: "/y", storagePath: "/y/.gitnexus" }], registryPath),
  ).rejects.toThrow();

  const onDisk = readFileSync(registryPath, "utf8");
  expect(onDisk).toBe(truncated);
});

test("updateRegistry writes atomically: a killed write never truncates the real file", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "registry.json");
  const original: RegistryEntry[] = [{ name: "keep-me", path: "/x", storagePath: "/x/.gitnexus" }];
  writeFileSync(registryPath, JSON.stringify(original, null, 2));

  const registryTsPath = join(import.meta.dir, "registry.ts");
  const scriptPath = join(dir, "slow-update.ts");
  writeFileSync(
    scriptPath,
    [
      `import { updateRegistry } from ${JSON.stringify(registryTsPath)};`,
      `await updateRegistry(`,
      `  (entries) => [...entries, { name: "new", path: "/y", storagePath: "/y/.gitnexus" }],`,
      `  ${JSON.stringify(registryPath)},`,
      `  { testDelayBeforeRenameMs: 5000 },`,
      `);`,
    ].join("\n"),
  );

  const proc = Bun.spawn(["bun", "run", scriptPath], { stdout: "ignore", stderr: "ignore" });
  // Long enough for the subprocess to acquire the lock, write the temp file,
  // and be parked in the artificial pre-rename delay -- but nowhere near
  // enough to reach rename(). Killing here simulates a crash mid-write.
  await new Promise((r) => setTimeout(r, 500));
  proc.kill("SIGKILL");
  await proc.exited;

  const onDisk = readFileSync(registryPath, "utf8");
  expect(() => JSON.parse(onDisk)).not.toThrow();
  expect(JSON.parse(onDisk)).toEqual(original);
});

test("concurrent updateRegistry calls: N concurrent appends must all land", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "registry.json");
  writeFileSync(registryPath, JSON.stringify([], null, 2));

  const N = 20;
  await Promise.all(
    Array.from({ length: N }, (_, i) =>
      updateRegistry(
        (entries) => [
          ...entries,
          { name: `repo-${i}`, path: `/r${i}`, storagePath: `/r${i}/.gitnexus` },
        ],
        registryPath,
      ),
    ),
  );

  const final = await readRegistry(registryPath);
  expect(final.length).toBe(N);
  expect(new Set(final.map((e) => e.name)).size).toBe(N);
});

test("round-trip preserves unmodeled/optional fields (e.g. branches)", async () => {
  const dir = fixtureDir();
  const registryPath = join(dir, "registry.json");
  const original = [
    {
      name: "olympus-sdk",
      path: "/Users/x/projects/personal/olympus-sdk",
      storagePath: "/Users/x/projects/personal/olympus-sdk/.gitnexus",
      indexedAt: "2026-07-07T02:11:54.001Z",
      lastCommit: "5bae710",
      remoteUrl: "git@github.com:nwlnexus/olympus-sdk",
      stats: { files: 655, nodes: 10480, edges: 16318, communities: 220, processes: 300, embeddings: 0 },
      branch: "main",
      branches: [
        { branch: "main", indexedAt: "2026-07-07T02:11:54.001Z", lastCommit: "5bae710", stats: {} },
      ],
    },
  ];
  writeFileSync(registryPath, JSON.stringify(original, null, 2));

  await updateRegistry(
    (entries) =>
      entries.map((e) => (e.name === "olympus-sdk" ? { ...e, lastCommit: "new-sha" } : e)),
    registryPath,
  );

  const result = await readRegistry(registryPath);
  expect(result[0].lastCommit).toBe("new-sha");
  expect(result[0].branch).toBe("main");
  expect(result[0].branches).toEqual(original[0].branches);
});
