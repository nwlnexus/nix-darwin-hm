import { parseArgs } from "node:util";
import type { JobContext, Phase } from "./types";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";

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
  if (phase !== 1 && phase !== 2 && phase !== "all") {
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

if (import.meta.main) {
  const ctx = buildContext(process.argv.slice(2));
  await mkdir(ctx.outDir, { recursive: true });
  console.log(JSON.stringify(ctx, null, 2));
}
