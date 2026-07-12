import { $ } from "bun";
import { RepoTarget } from "./types";
import { existsSync } from "node:fs";
import { join } from "node:path";

export async function checkout(
  target: RepoTarget,
  cacheRoot: string,
): Promise<{ dir: string; defaultBranch: string; headSha: string }> {
  const dir = join(cacheRoot, target.owner, target.name);
  const headRef = (await $`git ls-remote --symref ${target.originUrl} HEAD`.text())
    .split("\n")[0];
  const m = headRef.match(/ref:\s+refs\/heads\/(\S+)\s+HEAD/);
  const defaultBranch = m ? m[1] : "main";

  if (!existsSync(join(dir, ".git"))) {
    await $`git clone --depth 1 --branch ${defaultBranch} ${target.originUrl} ${dir}`.quiet();
  } else {
    await $`git -C ${dir} fetch --depth 1 origin ${defaultBranch}`.quiet();
    await $`git -C ${dir} reset --hard origin/${defaultBranch}`.quiet();
    await $`git -C ${dir} clean -fdx`.quiet();
  }
  const headSha = (await $`git -C ${dir} rev-parse HEAD`.text()).trim();
  return { dir, defaultBranch, headSha };
}
