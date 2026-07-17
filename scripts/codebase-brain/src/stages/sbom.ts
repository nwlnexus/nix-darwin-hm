import { $ } from "bun";
import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { JobContext } from "../types";
import { fileDigest } from "../digests";

export async function parseSbomDigest(sbomPath: string): Promise<string> {
  return fileDigest(sbomPath);
}

export async function runSbom(ctx: JobContext): Promise<{ sbomPath: string; sbomDigest: string }> {
  await mkdir(ctx.outDir, { recursive: true });
  const sbomPath = join(ctx.outDir, "sbom.cdx.json");
  const res = await $`syft ${ctx.workDir} -o cyclonedx-json=${sbomPath}`.quiet().nothrow();
  if (res.exitCode !== 0) {
    throw new Error(`syft failed (${res.exitCode}): ${res.stderr.toString()}`);
  }
  return { sbomPath, sbomDigest: await parseSbomDigest(sbomPath) };
}
