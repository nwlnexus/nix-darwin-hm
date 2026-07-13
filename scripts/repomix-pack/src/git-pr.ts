import { $ } from "bun";
import { RepoTarget } from "./types";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { withGhTokenForGroup } from "./auth";

/**
 * Stage `files` onto the deterministic automation branch (branched fresh off
 * `base`) and, IFF the staged tree differs from `base`, commit and push.
 *
 * The gate is "any staged diff against base" — not any single file's content
 * hash. This is what lets a graph-only change (e.g. gitnexus rewriting
 * CLAUDE.md/AGENTS.md) produce a commit/PR even when the repomix pack itself
 * is byte-identical to what's already on `base`. Missing files (a repo with
 * no CLAUDE.md/AGENTS.md) are simply skipped, not an error.
 *
 * Returns `{ committed: false }` when nothing changed — callers must treat
 * that as a no-op: no push happened, so there's nothing to open/update a PR
 * for and nothing to notify about.
 *
 * The branch is cut from `origin/<base>` (the remote-tracking ref), NOT the
 * bare `<base>` (the LOCAL branch). This is load-bearing. Checkouts live in a
 * cache that persists across sweeps, and `checkout()` refreshes them with
 * `reset --hard origin/<base>`, which only moves the branch HEAD is currently
 * on. Since we leave HEAD on the automation branch, the local `<base>` is
 * never advanced again and stays pinned at the original clone commit. Diffing
 * against that stale ref means that after an automation PR is merged, every
 * subsequent sweep would see a phantom diff, force-push, open an empty PR and
 * fire Slack — forever — and, because the branch was cut from stale `<base>`,
 * revert whatever unrelated upstream commits had landed in the meantime.
 */
export async function commitToBranch(
  dir: string,
  target: RepoTarget,
  base: string,
  files: string[],
): Promise<{ committed: boolean }> {
  const snapshots = new Map<string, Buffer>();
  for (const f of files) {
    const p = join(dir, f);
    if (existsSync(p)) snapshots.set(f, readFileSync(p));
  }
  const co = await $`git -C ${dir} checkout -B ${target.branch} ${"origin/" + base}`.quiet().nothrow();
  if (co.exitCode !== 0) {
    throw new Error(`git checkout failed (${co.exitCode}): ${co.stderr.toString()}`);
  }
  for (const [f, content] of snapshots) {
    const p = join(dir, f);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, content);
  }
  for (const f of files) {
    if (!existsSync(join(dir, f))) continue;
    await $`git -C ${dir} add -f ${f}`.quiet();
  }
  const diff = await $`git -C ${dir} diff --cached --quiet`.quiet().nothrow();
  if (diff.exitCode === 0) {
    return { committed: false };
  }
  const commit = await $`git -C ${dir} -c commit.gpgsign=false -c user.email=repomix-bot@nwlnexus.io -c user.name=repomix-pipeline commit -qm ${"chore: refresh repomix context pack"}`.quiet().nothrow();
  if (commit.exitCode !== 0) {
    throw new Error(`git commit failed (${commit.exitCode}): ${commit.stderr.toString()}`);
  }
  const push = await $`git -C ${dir} push -f origin ${target.branch}`.quiet().nothrow();
  if (push.exitCode !== 0) {
    throw new Error(`git push failed (${push.exitCode}): ${push.stderr.toString()}`);
  }
  return { committed: true };
}

export function isMissingLabelError(output: string): boolean {
  return output.toLowerCase().includes("not found");
}

async function createGhPr(
  target: RepoTarget,
  base: string,
  title: string,
  body: string,
): Promise<string> {
  const withLabel = await $`gh pr create --repo ${target.slug} --base ${base} --head ${target.branch} --title ${title} --body ${body} --label automation`
    .quiet().nothrow();
  if (withLabel.exitCode === 0) {
    return withLabel.stdout.toString().trim();
  }
  const output = withLabel.stderr.toString() + withLabel.stdout.toString();
  if (isMissingLabelError(output)) {
    const retry = await $`gh pr create --repo ${target.slug} --base ${base} --head ${target.branch} --title ${title} --body ${body}`.text();
    return retry.trim();
  }
  throw new Error(`gh pr create failed (${withLabel.exitCode}): ${output}`);
}

export async function openOrUpdatePr(
  target: RepoTarget,
  base: string,
  title: string,
  body: string,
): Promise<{ url: string; created: boolean }> {
  return withGhTokenForGroup(target.group, async () => {
    const existing = await $`gh pr list --repo ${target.slug} --head ${target.branch} --state open --json url --jq ".[0].url"`
      .quiet().nothrow();
    const url0 = existing.stdout.toString().trim();
    if (url0) {
      await $`gh pr edit ${url0} --title ${title} --body ${body}`.quiet().nothrow();
      return { url: url0, created: false };
    }
    const url = await createGhPr(target, base, title, body);
    return { url, created: true };
  });
}
