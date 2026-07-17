import { parseArgs } from "node:util";
import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import type { Digests, GraphRef, JobContext, Phase } from "./types";
import { shouldSkipLlm, TEMPLATE_VERSION } from "./digests";
import { cloneAtSha } from "./stages/clone";
import { runPackStage } from "./stages/pack";
import { runAnalyzeStage } from "./stages/analyze";
import { runFacetsStage } from "./stages/facets";
import { runSbom } from "./stages/sbom";
import { hasR2Creds, publishGraph } from "./publish/r2-graph";
import { runOpenWiki } from "./stages/openwiki";
import { normalizeWikiDir } from "./stages/normalize";
import { writeInventoryPage } from "./stages/inventory";
import { publishBrainPr } from "./publish/brain-pr";

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
    r2Bucket: process.env.BRAIN_R2_BUCKET ?? "nwl-codebase-brain",
    r2Prefix: "graphs",
    anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    dryRun: Boolean(values["dry-run"]),
    phase,
  };
}

export function previousDigestsMarkerPath(ctx: JobContext): string {
  return join(dirname(ctx.outDir), "latest-digests.json");
}

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

export async function parseDigestsMarker(raw: unknown): Promise<Digests | null> {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const candidate = (obj.digests ?? obj) as Record<string, unknown>;
  if (
    typeof candidate.packHash === "string" &&
    typeof candidate.graphDigest === "string" &&
    typeof candidate.sbomDigest === "string" &&
    typeof candidate.templateVersion === "string"
  ) {
    return {
      packHash: candidate.packHash,
      graphDigest: candidate.graphDigest,
      sbomDigest: candidate.sbomDigest,
      templateVersion: candidate.templateVersion,
    };
  }
  return null;
}

async function readDigestsFile(path: string): Promise<Digests | null> {
  const file = Bun.file(path);
  if (!(await file.exists())) return null;
  try {
    return parseDigestsMarker(await file.json());
  } catch {
    return null;
  }
}

function latestJsonKey(ctx: JobContext): string {
  return `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest.json`;
}

async function fetchDigestsFromR2(ctx: JobContext): Promise<Digests | null> {
  if (!hasR2Creds()) return null;
  try {
    const client = new S3Client({
      region: "auto",
      endpoint: process.env.AWS_ENDPOINT_URL,
      credentials: {
        accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
        secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
      },
    });
    const res = await client.send(
      new GetObjectCommand({ Bucket: ctx.r2Bucket, Key: latestJsonKey(ctx) }),
    );
    const body = await res.Body?.transformToString();
    if (!body) return null;
    return parseDigestsMarker(JSON.parse(body));
  } catch {
    return null;
  }
}

export async function loadPreviousDigests(ctx: JobContext): Promise<Digests | null> {
  if (ctx.dryRun || !hasR2Creds()) {
    return readDigestsFile(previousDigestsMarkerPath(ctx));
  }
  return fetchDigestsFromR2(ctx);
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
}

if (import.meta.main) {
  const ctx = buildContext(process.argv.slice(2));
  await runJob(ctx);
}
