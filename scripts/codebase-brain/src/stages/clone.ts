import { $ } from "bun";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";

/** HTTPS clone URL; embeds GH_TOKEN/GITHUB_TOKEN when set (private allowlisted repos). */
export function cloneUrl(ctx: JobContext, env: NodeJS.ProcessEnv = process.env): string {
  const token = env.GH_TOKEN ?? env.GITHUB_TOKEN;
  if (token) {
    return `https://x-access-token:${token}@github.com/${ctx.owner}/${ctx.repo}.git`;
  }
  return `https://github.com/${ctx.owner}/${ctx.repo}.git`;
}

function redactUrl(url: string): string {
  return url.replace(/x-access-token:[^@]+@/i, "x-access-token:***@");
}

export async function cloneAtSha(ctx: JobContext): Promise<void> {
  await mkdir(ctx.workDir, { recursive: true });
  const url = cloneUrl(ctx);
  const exists = await Bun.file(`${ctx.workDir}/.git/HEAD`).exists();
  if (!exists) {
    const r = await $`git clone --filter=blob:none ${url} ${ctx.workDir}`.quiet().nothrow();
    if (r.exitCode !== 0) {
      throw new Error(
        `clone failed (${r.exitCode}): ${r.stderr.toString() || redactUrl(url)}`,
      );
    }
  }
  const f = await $`git -C ${ctx.workDir} fetch --depth=1 origin ${ctx.sha}`.quiet().nothrow();
  if (f.exitCode !== 0) {
    await $`git -C ${ctx.workDir} fetch origin`.quiet().nothrow();
  }
  const c = await $`git -C ${ctx.workDir} checkout --force ${ctx.sha}`.quiet().nothrow();
  if (c.exitCode !== 0) {
    throw new Error(`checkout ${ctx.sha} failed (${c.exitCode}): ${c.stderr.toString()}`);
  }
}
