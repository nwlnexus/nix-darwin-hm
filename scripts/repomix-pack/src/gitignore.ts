import { $ } from "bun";
import { join, dirname } from "node:path";
import { appendFileSync, existsSync, readFileSync } from "node:fs";

export async function ensureTracked(
  dir: string,
  packPath: string,
): Promise<{ patched: boolean }> {
  const ck = await $`git -C ${dir} check-ignore ${packPath}`.nothrow().quiet();
  if (ck.exitCode !== 0) return { patched: false };
  const negation = `!/${dirname(packPath)}/`;
  const giPath = join(dir, ".gitignore");
  const existing = existsSync(giPath) ? readFileSync(giPath, "utf8") : "";
  if (!existing.split("\n").includes(negation)) {
    appendFileSync(giPath, `\n# repomix pipeline: keep context pack tracked\n${negation}\n`);
  }
  return { patched: true };
}
