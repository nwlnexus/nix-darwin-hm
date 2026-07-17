import YAML from "yaml";
import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { NwlDocSchema } from "../schema/frontmatter";
import type { Digests, GraphRef, JobContext } from "../types";

const FM_RE = /^---\n([\s\S]*?)\n---\n?/;

export function splitFrontmatter(md: string): { fm: Record<string, unknown>; body: string } {
  const m = md.match(FM_RE);
  if (!m) return { fm: {}, body: md };
  return { fm: (YAML.parse(m[1]) as Record<string, unknown>) ?? {}, body: md.slice(m[0].length) };
}

export function guessDocType(name: string, fm: Record<string, unknown>): string {
  if (typeof fm.docType === "string") return fm.docType;
  const n = name.toLowerCase();
  if (n.includes("inventory")) return "inventory";
  if (n.includes("cluster")) return "cluster";
  return "overview";
}

export function stampNwlExtensions(
  md: string,
  fileName: string,
  ctx: JobContext,
  digests: Digests,
  graph: GraphRef,
): string {
  const { fm, body } = splitFrontmatter(md);
  const slugBase = basename(fileName, ".md").toLowerCase().replace(/\s+/g, "-");
  const docType = guessDocType(fileName, fm);
  const stamped = {
    ...fm,
    title: String(fm.title ?? `${ctx.repo} — ${slugBase}`),
    docType,
    repo: ctx.repo,
    owner: ctx.owner,
    slug: `${ctx.repo}/${slugBase}`,
    source: {
      sha: ctx.sha,
      packHash: digests.packHash,
      graphDigest: digests.graphDigest,
      graphUri: graph.r2Uri,
      templateVersion: digests.templateVersion,
    },
    brainPath: `${ctx.brainContentRoot}/${ctx.repo}/${slugBase}.md`,
    status: "generated" as const,
  };
  NwlDocSchema.parse(stamped);
  return `---\n${YAML.stringify(stamped).trim()}\n---\n\n${body.trimStart()}`;
}

export async function normalizeWikiDir(
  wikiDir: string,
  ctx: JobContext,
  digests: Digests,
  graph: GraphRef,
): Promise<string[]> {
  const outDir = join(ctx.outDir, "brain-docs", ctx.repo);
  await mkdir(outDir, { recursive: true });
  const written: string[] = [];
  const entries = await readdir(wikiDir, { recursive: true });
  for (const rel of entries) {
    if (typeof rel !== "string" || !rel.endsWith(".md")) continue;
    if (rel.includes("_plan") || rel.startsWith("_")) continue;
    const raw = await readFile(join(wikiDir, rel), "utf8");
    const stamped = stampNwlExtensions(raw, rel, ctx, digests, graph);
    const destName = basename(rel);
    const dest = join(outDir, destName);
    await writeFile(dest, stamped);
    written.push(dest);
  }
  return written;
}
