import { $ } from "bun";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest } from "../digests";

export function graphDirPath(workDir: string): string {
  return join(workDir, ".gitnexus");
}

export function graphTarballPath(ctx: JobContext): string {
  return join(ctx.outDir, `graph-${ctx.sha}.tgz`);
}

export async function parseGraphDigest(tarballPath: string): Promise<string> {
  return fileDigest(tarballPath);
}

export async function runAnalyzeStage(ctx: JobContext): Promise<{
  graphDir: string;
  graphDigest: string;
  tarballPath: string;
}> {
  const res = await $`gitnexus analyze`.cwd(ctx.workDir).quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(`gitnexus analyze failed (${res.exitCode}): ${res.stderr.toString()}`);
  }
  const graphDir = graphDirPath(ctx.workDir);
  await mkdir(ctx.outDir, { recursive: true });
  const tarballPath = graphTarballPath(ctx);
  const tar = await $`tar -czf ${tarballPath} -C ${ctx.workDir} .gitnexus`.quiet().nothrow();
  if (tar.exitCode !== 0) {
    throw new Error(`tar graph failed (${tar.exitCode}): ${tar.stderr.toString()}`);
  }
  const graphDigest = await parseGraphDigest(tarballPath);
  return { graphDir, graphDigest, tarballPath };
}
