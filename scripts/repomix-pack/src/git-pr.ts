import { $ } from "bun";
import { RepoTarget } from "./types";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { withGhTokenForGroup } from "./auth";

export async function commitToBranch(
  dir: string,
  target: RepoTarget,
  base: string,
  files: string[],
): Promise<void> {
  const snapshots = new Map<string, Buffer>();
  for (const f of files) {
    const p = join(dir, f);
    if (existsSync(p)) snapshots.set(f, readFileSync(p));
  }
  const co = await $`git -C ${dir} checkout -B ${target.branch} ${base}`.quiet().nothrow();
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
  const commit = await $`git -C ${dir} -c commit.gpgsign=false -c user.email=repomix-bot@nwlnexus.io -c user.name=repomix-pipeline commit -qm ${"chore: refresh repomix context pack"}`.quiet().nothrow();
  if (commit.exitCode !== 0) {
    throw new Error(`git commit failed (${commit.exitCode}): ${commit.stderr.toString()}`);
  }
  const push = await $`git -C ${dir} push -f origin ${target.branch}`.quiet().nothrow();
  if (push.exitCode !== 0) {
    throw new Error(`git push failed (${push.exitCode}): ${push.stderr.toString()}`);
  }
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
