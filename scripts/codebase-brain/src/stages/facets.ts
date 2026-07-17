import { join } from "node:path";
import type { JobContext } from "../types";

export function facetsOutPath(ctx: JobContext): string {
  return join(ctx.outDir, "facet.json");
}

export function buildFacetsPayload(ctx: JobContext, graphDir: string) {
  return {
    repo: ctx.repo,
    owner: ctx.owner,
    sha: ctx.sha,
    graphDir,
    note: "v1 facets are thin; cluster supplements optional later",
  };
}

export async function runFacetsStage(ctx: JobContext, graphDir: string): Promise<string> {
  const out = facetsOutPath(ctx);
  const payload = buildFacetsPayload(ctx, graphDir);
  await Bun.write(out, JSON.stringify(payload, null, 2));
  return out;
}
