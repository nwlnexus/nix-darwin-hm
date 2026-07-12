import { test, expect } from "bun:test";
import { commitToBranch } from "./git-pr";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("commits pack to deterministic branch and pushes to origin", async () => {
  const root = mkdtempSync(join(tmpdir(), "gp-"));
  const bare = join(root, "origin.git");
  await $`git init -q --bare ${bare}`;
  const dir = join(root, "clone");
  await $`git clone -q ${bare} ${dir}`;
  await $`git -C ${dir} config user.email t@t`;
  await $`git -C ${dir} config user.name t`;
  writeFileSync(join(dir, "seed"), "1");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false commit -qm seed`;
  await $`git -C ${dir} push -q origin HEAD:main`;

  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget", sshHost: "github.com",
    originUrl: bare, defaultBranch: "main", packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack", group: "personal",
  };
  await commitToBranch(dir, target as any, "main", [".llm/repomix.xml"]);

  const branches = await $`git -C ${bare} branch`.text();
  expect(branches).toContain("automation/repomix-pack");
  const show = await $`git -C ${bare} show automation/repomix-pack:.llm/repomix.xml`.text();
  expect(show.trim()).toBe("PACK");
});
