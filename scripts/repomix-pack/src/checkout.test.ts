import { test, expect } from "bun:test";
import { checkout } from "./checkout";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

async function fakeOrigin(): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "origin-"));
  const work = join(dir, "work");
  mkdirSync(work);
  await $`git -C ${work} init -q -b main`;
  writeFileSync(join(work, "README.md"), "hello");
  await $`git -C ${work} add -A`;
  await $`git -C ${work} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init`;
  const bare = join(dir, "origin.git");
  await $`git clone -q --bare ${work} ${bare}`;
  return bare;
}

test("clones origin into cache and reports head", async () => {
  const origin = await fakeOrigin();
  const cacheRoot = mkdtempSync(join(tmpdir(), "cache-"));
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget",
    sshHost: "github.com", originUrl: origin, defaultBranch: null,
    packPath: ".llm/repomix.xml", branch: "automation/repomix-pack", group: "personal",
  };
  const res = await checkout(target as any, cacheRoot);
  expect(res.defaultBranch).toBe("main");
  expect(res.headSha).toMatch(/^[0-9a-f]{40}$/);
  expect(await Bun.file(join(res.dir, "README.md")).text()).toBe("hello");
});
