import { join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import type { Digests, GraphRef, JobContext } from "../types";

export interface SbomComponent {
  name: string;
  version?: string;
  type?: string;
}
export interface Sbom {
  bomFormat?: string;
  components?: SbomComponent[];
}

export function renderInventory(sbom: Sbom): string {
  const comps = (sbom.components ?? [])
    .filter((c) => c.name)
    .sort((a, b) => a.name.localeCompare(b.name));
  const rows = comps
    .map((c) => `| ${c.name} | ${c.version ?? ""} | ${c.type ?? ""} |`)
    .join("\n");
  return [
    `Components: ${comps.length}`,
    "",
    "| Name | Version | Type |",
    "| --- | --- | --- |",
    rows,
    "",
  ].join("\n");
}

export async function writeInventoryPage(
  ctx: JobContext,
  sbomPath: string,
  digests: Digests,
  graph: GraphRef,
): Promise<string> {
  const sbom = (await Bun.file(sbomPath).json()) as Sbom;
  const body = renderInventory(sbom);
  const fm = [
    "---",
    "type: Tech Inventory",
    `title: ${ctx.repo} — Tech Inventory`,
    "description: CycloneDX-derived dependency inventory",
    "tags: [sbom, inventory]",
    "docType: inventory",
    `repo: ${ctx.repo}`,
    `owner: ${ctx.owner}`,
    `slug: ${ctx.repo}/tech-inventory`,
    "source:",
    `  sha: ${ctx.sha}`,
    `  packHash: ${digests.packHash}`,
    `  graphDigest: ${digests.graphDigest}`,
    `  graphUri: ${graph.r2Uri}`,
    `  templateVersion: ${digests.templateVersion}`,
    `brainPath: ${ctx.brainContentRoot}/${ctx.repo}/tech-inventory.md`,
    "status: generated",
    "---",
    "",
    body,
  ].join("\n");
  const docsDir = join(ctx.outDir, "brain-docs", ctx.repo);
  await mkdir(docsDir, { recursive: true });
  const out = join(docsDir, "tech-inventory.md");
  await writeFile(out, fm);
  return out;
}
