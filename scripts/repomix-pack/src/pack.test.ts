import { test, expect } from "bun:test";
import { contentHash } from "./hash";
import { packChanged } from "./pack";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("contentHash is stable and sensitive", () => {
  expect(contentHash("a")).toBe(contentHash("a"));
  expect(contentHash("a")).not.toBe(contentHash("b"));
});

test("packChanged true when committed pack differs, false when identical", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "OLD");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm base`;

  writeFileSync(join(dir, ".llm/repomix.xml"), "NEW");
  const changed = await packChanged(dir, ".llm/repomix.xml");
  expect(changed.changed).toBe(true);
  expect(changed.bytes).toBe(3);

  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm new`;
  const same = await packChanged(dir, ".llm/repomix.xml");
  expect(same.changed).toBe(false);
});
