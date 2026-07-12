import { $ } from "bun";
import { RepoTarget } from "./types";
import { existsSync } from "node:fs";
import { join } from "node:path";

async function git(
  label: string,
  cmd: ReturnType<typeof $>,
): Promise<{ stdout: string; stderr: string }> {
  const res = await cmd.quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(
      `${label} failed (${res.exitCode}): ${res.stderr.toString() || res.stdout.toString()}`,
    );
  }
  return { stdout: res.stdout.toString(), stderr: res.stderr.toString() };
}

export async function checkout(
  target: RepoTarget,
  cacheRoot: string,
): Promise<{ dir: string; defaultBranch: string; headSha: string }> {
  const dir = join(cacheRoot, target.owner, target.name);
  const remote = await git(
    "git ls-remote",
    $`git ls-remote --symref ${target.originUrl} HEAD`,
  );
  const headRef = remote.stdout.split("\n")[0];
  const m = headRef.match(/ref:\s+refs\/heads\/(\S+)\s+HEAD/);
  const defaultBranch = m ? m[1] : "main";

  if (!existsSync(join(dir, ".git"))) {
    await git(
      "git clone",
      $`git clone --depth 1 --branch ${defaultBranch} ${target.originUrl} ${dir}`,
    );
  } else {
    await git(
      "git fetch",
      $`git -C ${dir} fetch --depth 1 origin ${defaultBranch}`,
    );
    await git(
      "git reset",
      $`git -C ${dir} reset --hard origin/${defaultBranch}`,
    );
    await git("git clean", $`git -C ${dir} clean -fdx`);
  }
  const head = await git("git rev-parse", $`git -C ${dir} rev-parse HEAD`);
  return { dir, defaultBranch, headSha: head.stdout.trim() };
}
