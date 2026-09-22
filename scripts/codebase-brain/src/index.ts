import { parseArgs } from "node:util";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { Digests, GraphRef, JobContext, Phase } from "./types";
import { parseDigestsMarker, shouldSkipLlm, TEMPLATE_VERSION } from "./digests";
import { cloneAtSha } from "./stages/clone";
import { runPackStage } from "./stages/pack";
import { runAnalyzeStage } from "./stages/analyze";
import { runFacetsStage } from "./stages/facets";
import { runSbom } from "./stages/sbom";
import {
  fetchDigestsMarker,
  hasR2Creds,
  localDigestsMarkerPath,
  publishDigestsMarker,
  publishGraph,
  readLocalDigestsMarker,
} from "./publish/r2-graph";
import { runOpenWiki } from "./stages/openwiki";
import { normalizeWikiDir } from "./stages/normalize";
import { writeInventoryPage } from "./stages/inventory";
import { publishBrainPr } from "./publish/brain-pr";

export { parseDigestsMarker } from "./digests";

export function buildContext(argv: string[]): JobContext {
  const { values } = parseArgs({
    args: argv,
    options: {
      owner: { type: "string", default: "nwlnexus" },
      repo: { type: "string" },
      sha: { type: "string" },
      phase: { type: "string", default: "all" },
      "work-root": { type: "string", default: "/tmp/codebase-brain-job" },
      "dry-run": { type: "boolean", default: false },
      "brain-repo": { type: "string", default: "second-brain" },
      "config-path": {
        type: "string",
        default: new URL("../../../modules/repomix/repomix.config.json", import.meta.url)
          .pathname,
      },
    },
    strict: true,
  });
  if (!values.repo || !values.sha) throw new Error("--repo and --sha are required");
  const phase = values.phase as Phase;
  if (phase !== "1" && phase !== "2" && phase !== "all") {
    throw new Error("--phase must be 1 | 2 | all");
  }
  const workRoot = values["work-root"]!;
  const workDir = join(workRoot, "repos", values.owner!, values.repo);
  const outDir = join(workRoot, "out", values.owner!, values.repo, values.sha);
  return {
    owner: values.owner!,
    repo: values.repo,
    sha: values.sha,
    workDir,
    outDir,
    packPath: ".llm/repomix.xml",
    configPath: values["config-path"]!,
    brainRepo: values["brain-repo"]!,
    brainContentRoot: "docs/codebases",
    r2Bucket: process.env.BRAIN_R2_BUCKET ?? "second-brain-docs",
    r2Prefix: "graphs",
    anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    dryRun: Boolean(values["dry-run"]),
    phase,
  };
}

/** @deprecated use localDigestsMarkerPath from r2-graph */
export const previousDigestsMarkerPath = localDigestsMarkerPath;

export function manifestPath(ctx: JobContext): string {
  return join(ctx.outDir, "manifest.json");
}

export function buildManifest(digests: Digests, skipLlm: boolean, graph: GraphRef) {
  return { digests, skipLlm, graph };
}

export function shouldRunLlmSection(phase: Phase, skipLlm: boolean): boolean {
  if (phase === "1") return false;
  if (skipLlm) return false;
  return true;
}

export async function loadPreviousDigests(ctx: JobContext): Promise<Digests | null> {
  if (ctx.dryRun || !hasR2Creds()) {
    return readLocalDigestsMarker(ctx);
  }
  return fetchDigestsMarker(ctx);
}

export async function runJob(ctx: JobContext): Promise<void> {
  await mkdir(ctx.outDir, { recursive: true });
  await cloneAtSha(ctx);
  const { packHash } = await runPackStage(ctx);
  const { graphDir, graphDigest, tarballPath } = await runAnalyzeStage(ctx);
  await runFacetsStage(ctx, graphDir);
  const { sbomPath, sbomDigest } = await runSbom(ctx);
  const digests: Digests = {
    packHash,
    graphDigest,
    sbomDigest,
    templateVersion: TEMPLATE_VERSION,
  };
  const prev = await loadPreviousDigests(ctx);
  const graph = await publishGraph(ctx, tarballPath, graphDigest);
  const skipLlm = shouldSkipLlm(digests, prev);
  await Bun.write(manifestPath(ctx), JSON.stringify(buildManifest(digests, skipLlm, graph), null, 2));

  if (!shouldRunLlmSection(ctx.phase, skipLlm)) {
    if (ctx.phase !== "1" && skipLlm) {
      console.log("skip LLM: digests unchanged");
    }
    return;
  }

  const { wikiDir } = await runOpenWiki(ctx);
  await normalizeWikiDir(wikiDir, ctx, digests, graph);
  await writeInventoryPage(ctx, sbomPath, digests, graph);
  await publishBrainPr(ctx);
  // Marker means "narrative + brain PR completed for these digests" — write it
  // only after the LLM section succeeds, never on the phase-1 or skip paths.
  await publishDigestsMarker(ctx, digests);
}

if (import.meta.main) {
  const ctx = buildContext(process.argv.slice(2));
  await runJob(ctx);
}
