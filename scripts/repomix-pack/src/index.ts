import { loadTargets } from "./config";
import { checkout } from "./checkout";
import { runPack, packChanged } from "./pack";
import { ensureTracked } from "./gitignore";
import { commitToBranch, openOrUpdatePr } from "./git-pr";
import { StagingSink, RepoMeta } from "./sink";
import { buildSlackPayload, resolveWebhook, notifySlack } from "./notify";
import { join } from "node:path";

export interface RunSummary {
  succeeded: string[];
  skipped: string[];
  failed: { slug: string; error: string }[];
  prs: { slug: string; url: string }[];
}

export interface RunOpts {
  tomlPath: string;
  configPath: string;
  cacheRoot: string;
  brainRoot: string;
  group?: string;
  only?: string[];
  dryRun?: boolean;
  noPr?: boolean;
  brainOnly?: boolean;
  noNotify?: boolean;
  originOverride?: Record<string, string>;
  concurrency?: number;
}

export async function run(opts: RunOpts): Promise<RunSummary> {
  const targets = loadTargets(opts.tomlPath, { group: opts.group, only: opts.only });
  const sink = new StagingSink(opts.brainRoot);
  const webhook = opts.noNotify ? "" : await resolveWebhook();
  const summary: RunSummary = { succeeded: [], skipped: [], failed: [], prs: [] };
  const limit = opts.concurrency ?? 4;

  const queue = [...targets];
  async function worker() {
    for (let t = queue.shift(); t; t = queue.shift()) {
      try {
        if (opts.originOverride?.[t.slug]) t.originUrl = opts.originOverride[t.slug];
        const { dir, defaultBranch, headSha } = await checkout(t, opts.cacheRoot);
        await runPack(dir, opts.configPath);
        // `gate` still tells us whether the pack itself changed, which drives
        // the brain-staging sink and the PR body's byte count. It is NOT the
        // PR gate anymore — see commitToBranch, which gates on any staged
        // diff against base (pack, .gitignore, CLAUDE.md, AGENTS.md), so a
        // graph-only refresh (pack unchanged) still produces a PR.
        const gate = await packChanged(dir, t.packPath);

        if (gate.changed) {
          const packBytes = new Uint8Array(
            await Bun.file(join(dir, t.packPath)).arrayBuffer(),
          );
          const meta: RepoMeta = {
            slug: t.slug, owner: t.owner, name: t.name, commit: headSha,
            hash: gate.newHash, bytes: gate.bytes, ts: new Date().toISOString(),
          };
          await sink.write(packBytes, meta);
        }

        let committed = false;
        if (!opts.brainOnly && !opts.dryRun) {
          await ensureTracked(dir, t.packPath);
          const result = await commitToBranch(
            dir, t, defaultBranch,
            [t.packPath, ".gitignore", "CLAUDE.md", "AGENTS.md"],
          );
          committed = result.committed;
          if (committed && !opts.noPr) {
            const pr = await openOrUpdatePr(
              t, defaultBranch, "chore: refresh repomix context pack",
              `Automated repomix context pack refresh.\n\nCloses the paired tracking sub-issue.\nPack: \`${t.packPath}\` (${gate.bytes} bytes).`,
            );
            summary.prs.push({ slug: t.slug, url: pr.url });
            await notifySlack(webhook, buildSlackPayload({
              slug: t.slug, base: defaultBranch, prUrl: pr.url,
              created: pr.created, bytes: gate.bytes,
            }));
          }
        }

        if (!gate.changed && !committed) {
          summary.skipped.push(t.slug);
        } else {
          summary.succeeded.push(t.slug);
        }
      } catch (e) {
        summary.failed.push({ slug: t.slug, error: String(e) });
      }
    }
  }
  await Promise.all(Array.from({ length: limit }, worker));
  return summary;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const has = (f: string) => args.includes(f);
  const val = (f: string) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
  const home = process.env.HOME!;
  const groupArg = val("--group");
  const group = groupArg === "all" ? undefined : groupArg;
  const summary = await run({
    tomlPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repos.toml`,
    configPath: `${home}/projects/personal/nix-darwin-hm/modules/repomix/repomix.config.json`,
    cacheRoot: `${home}/.cache/repomix-pipeline`,
    brainRoot: `${home}/.cache/repomix-pipeline/brain-staging`,
    group,
    only: has("--only") ? args.slice(args.indexOf("--only") + 1).filter((a) => a.includes("/")) : undefined,
    dryRun: has("--dry-run"), noPr: has("--no-pr"),
    brainOnly: has("--brain-only"), noNotify: has("--no-notify"),
  });
  console.log(JSON.stringify(summary, null, 2));
  if (summary.failed.length) process.exit(1);
}
