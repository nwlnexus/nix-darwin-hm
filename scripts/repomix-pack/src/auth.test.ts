import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveGhTokenForGroup, withGhTokenForGroup } from "./auth";

let home: string;
const prevHome = process.env.HOME;
const prevGhToken = process.env.GH_TOKEN;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "auth-"));
  process.env.HOME = home;
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
  if (prevHome === undefined) delete process.env.HOME;
  else process.env.HOME = prevHome;
  if (prevGhToken === undefined) delete process.env.GH_TOKEN;
  else process.env.GH_TOKEN = prevGhToken;
});

function writeGroupEnv(group: string, content: string) {
  const dir = join(home, "projects", group);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, ".env"), content);
}

test("resolves token from personal group env file", () => {
  writeGroupEnv("personal", "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_personal\n");
  expect(resolveGhTokenForGroup("personal")).toBe("ghp_personal");
});

test("resolves token from work group env file", () => {
  writeGroupEnv("work", 'GITHUB_PERSONAL_ACCESS_TOKEN="ghp_work"\n');
  expect(resolveGhTokenForGroup("work")).toBe("ghp_work");
});

test("returns undefined when env file is missing", () => {
  expect(resolveGhTokenForGroup("personal")).toBeUndefined();
});

test("ignores comments and unrelated keys", () => {
  writeGroupEnv("personal", "# comment\nFOO=bar\nGITHUB_PERSONAL_ACCESS_TOKEN='ghp_ok'\n");
  expect(resolveGhTokenForGroup("personal")).toBe("ghp_ok");
});

test("withGhTokenForGroup sets and restores GH_TOKEN", async () => {
  writeGroupEnv("work", "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_work\n");
  process.env.GH_TOKEN = "ghp_global";
  let seen: string | undefined;
  await withGhTokenForGroup("work", async () => {
    seen = process.env.GH_TOKEN;
  });
  expect(seen).toBe("ghp_work");
  expect(process.env.GH_TOKEN).toBe("ghp_global");
});

test("withGhTokenForGroup deletes GH_TOKEN when previously unset", async () => {
  writeGroupEnv("personal", "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_personal\n");
  delete process.env.GH_TOKEN;
  await withGhTokenForGroup("personal", async () => {
    expect(process.env.GH_TOKEN).toBe("ghp_personal");
  });
  expect(process.env.GH_TOKEN).toBeUndefined();
});
