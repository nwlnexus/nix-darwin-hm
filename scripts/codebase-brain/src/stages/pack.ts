import { $ } from "bun";
import { join } from "node:path";
import { copyFile, mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest } from "../digests";

export function packOutPath(ctx: JobContext): string {
  return join(ctx.outDir, "repomix.xml");
}

export async function parsePackDigest(packPath: string): Promise<string> {
  return fileDigest(packPath);
}

export async function runPackStage(ctx: JobContext): Promise<{ packOut: string; packHash: string }> {
  const res = await $`repomix --config ${ctx.configPath} .`.cwd(ctx.workDir).quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(`repomix failed (${res.exitCode}): ${res.stderr.toString()}`);
  }
  const src = join(ctx.workDir, ctx.packPath);
  await mkdir(ctx.outDir, { recursive: true });
  const packOut = packOutPath(ctx);
  await copyFile(src, packOut);
  return { packOut, packHash: await parsePackDigest(packOut) };
}
