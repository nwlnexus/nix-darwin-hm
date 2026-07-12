import { $ } from "bun";
import { RepoTarget } from "./types";

export async function commitToBranch(
  dir: string,
  target: RepoTarget,
  base: string,
  files: string[],
): Promise<void> {
  await $`git -C ${dir} checkout -B ${target.branch} ${base}`.quiet();
  for (const f of files) await $`git -C ${dir} add -f ${f}`.quiet();
  await $`git -C ${dir} -c commit.gpgsign=false -c user.email=repomix-bot@nwlnexus.io -c user.name=repomix-pipeline commit -qm ${"chore: refresh repomix context pack"}`.quiet();
  await $`git -C ${dir} push -f origin ${target.branch}`.quiet();
}

export async function openOrUpdatePr(
  target: RepoTarget,
  base: string,
  title: string,
  body: string,
): Promise<{ url: string; created: boolean }> {
  const existing = await $`gh pr list --repo ${target.slug} --head ${target.branch} --state open --json url --jq ".[0].url"`
    .quiet().nothrow();
  const url0 = existing.stdout.toString().trim();
  if (url0) {
    await $`gh pr edit ${url0} --title ${title} --body ${body}`.quiet().nothrow();
    return { url: url0, created: false };
  }
  const created = await $`gh pr create --repo ${target.slug} --base ${base} --head ${target.branch} --title ${title} --body ${body} --label automation`.text();
  return { url: created.trim(), created: true };
}
