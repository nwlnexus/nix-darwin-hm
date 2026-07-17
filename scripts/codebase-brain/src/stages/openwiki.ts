import { $ } from "bun";
import { join } from "node:path";
import { cp, mkdir, readdir, rm, stat } from "node:fs/promises";
import type { JobContext } from "../types";
import { isPublishableWikiRel } from "./strip-side-effects";

export function wikiDirPath(ctx: JobContext): string {
  return join(ctx.outDir, "openwiki-okf");
}

export function srcWikiPath(workDir: string): string {
  return join(workDir, "openwiki");
}

export function buildOpenWikiEnv(ctx: JobContext): NodeJS.ProcessEnv {
  if (!ctx.anthropicApiKey && !process.env.ANTHROPIC_API_KEY) {
    throw new Error("ANTHROPIC_API_KEY required for openwiki narrative");
  }
  return {
    ...process.env,
    ANTHROPIC_API_KEY: ctx.anthropicApiKey ?? process.env.ANTHROPIC_API_KEY!,
    OPENWIKI_PROVIDER: "anthropic",
    OPENWIKI_OKF: "1",
    ...(process.env.OPENWIKI_MODEL_ID
      ? { OPENWIKI_MODEL_ID: process.env.OPENWIKI_MODEL_ID }
      : {}),
  };
}

export async function copyPublishableWikiPages(
  srcWiki: string,
  wikiDir: string,
): Promise<string[]> {
  const copied: string[] = [];

  async function walk(dir: string, base = ""): Promise<void> {
    let entries: string[];
    try {
      entries = await readdir(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const rel = base ? `${base}/${name}` : name;
      const abs = join(dir, name);
      const s = await stat(abs);
      if (s.isDirectory()) {
        await walk(abs, rel);
      } else if (isPublishableWikiRel(rel)) {
        const dest = join(wikiDir, rel);
        await mkdir(join(dest, ".."), { recursive: true });
        await cp(abs, dest);
        copied.push(rel);
      }
    }
  }

  await walk(srcWiki);
  return copied;
}

export async function runOpenWiki(
  ctx: JobContext,
): Promise<{ wikiDir: string; wallClockSeconds: number }> {
  const env = buildOpenWikiEnv(ctx);
  const wikiDir = wikiDirPath(ctx);
  await rm(wikiDir, { recursive: true, force: true });
  await mkdir(wikiDir, { recursive: true });

  const started = Date.now();
  const logPath = join(wikiDir, "_run.log");
  const res = await $`openwiki code --update -p`.cwd(ctx.workDir).env(env).nothrow();
  await Bun.write(logPath, res.stdout.toString() + res.stderr.toString());
  if (res.exitCode !== 0) {
    throw new Error(`openwiki failed (${res.exitCode}); see ${logPath}`);
  }

  await copyPublishableWikiPages(srcWikiPath(ctx.workDir), wikiDir);
  return { wikiDir, wallClockSeconds: Math.round((Date.now() - started) / 1000) };
}
