import { test, expect } from "bun:test";
import { run } from "./index";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("run packs a repo and stages to brain (no PR)", async () => {
  const root = mkdtempSync(join(tmpdir(), "run-"));
  const work = join(root, "work");
  mkdirSync(work);
  await $`git -C ${work} init -q -b main`;
  writeFileSync(join(work, "app.ts"), "export const x = 1;\n");
  await $`git -C ${work} add -A`;
  await $`git -C ${work} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init`;
  const bare = join(root, "origin.git");
  await $`git clone -q --bare ${work} ${bare}`;

  const toml = join(root, "repos.toml");
  writeFileSync(toml, `
[defaults]
pack_path = ".llm/repomix.xml"
branch = "automation/repomix-pack"
[groups.personal]
base_dir = "~/projects/personal"
ssh_host = "github.com"
owner = "acme"
repos = ["widget"]
`);
  const cacheRoot = join(root, "cache");
  const brainRoot = join(root, "brain");
  const summary = await run({
    tomlPath: toml,
    configPath: join(process.cwd(), "..", "..", "modules/repomix/repomix.config.json"),
    cacheRoot, brainRoot, noPr: true, noNotify: true,
    originOverride: { "acme/widget": bare },
  });
  expect(summary.succeeded).toContain("acme/widget");
  expect(existsSync(join(brainRoot, "acme/widget.xml"))).toBe(true);
});
