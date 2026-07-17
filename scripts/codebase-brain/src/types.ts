export type Phase = 1 | 2 | "all";

export interface Digests {
  packHash: string;
  graphDigest: string;
  sbomDigest: string;
  templateVersion: string;
}

export interface GraphRef {
  owner: string;
  repo: string;
  sha: string;
  graphDigest: string;
  r2Uri: string;
  latestUri: string;
  intent: "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later";
}

export interface JobContext {
  owner: string;
  repo: string;
  sha: string;
  workDir: string;
  outDir: string;
  packPath: string;
  configPath: string;
  brainRepo: string;
  brainContentRoot: string;
  r2Bucket: string;
  r2Prefix: string;
  anthropicApiKey?: string;
  dryRun: boolean;
  phase: Phase;
}
