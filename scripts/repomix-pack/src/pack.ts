import { $ } from "bun";
import { join } from "node:path";
import { contentHash } from "./hash";

export async function runPack(dir: string, configPath: string): Promise<void> {
  await $`repomix --config ${configPath} ${dir}`.cwd(dir).quiet();
}

export async function packChanged(
  dir: string,
  packPath: string,
): Promise<{ changed: boolean; newHash: string; bytes: number }> {
  const newBytes = await Bun.file(join(dir, packPath)).arrayBuffer();
  const newHash = contentHash(new Uint8Array(newBytes));
  const committed = await $`git -C ${dir} show HEAD:${packPath}`.quiet().nothrow();
  const changed =
    committed.exitCode !== 0 || contentHash(committed.stdout) !== newHash;
  return { changed, newHash, bytes: newBytes.byteLength };
}
