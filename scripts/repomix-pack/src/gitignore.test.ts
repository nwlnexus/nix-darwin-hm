import { test, expect } from "bun:test";
import { ensureTracked } from "./gitignore";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

test("adds negation when pack dir is ignored", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  writeFileSync(join(dir, ".gitignore"), ".llm/\n");
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "x");

  const res = await ensureTracked(dir, ".llm/repomix.xml");
  expect(res.patched).toBe(true);
  expect(readFileSync(join(dir, ".gitignore"), "utf8")).toContain("!/.llm/");

  const ck = await $`git -C ${dir} check-ignore .llm/repomix.xml`.nothrow().quiet();
  expect(ck.exitCode).not.toBe(0);
});

test("no-op when already tracked", async () => {
  const dir = mkdtempSync(join(tmpdir(), "repo-"));
  await $`git -C ${dir} init -q -b main`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "x");
  const res = await ensureTracked(dir, ".llm/repomix.xml");
  expect(res.patched).toBe(false);
});
