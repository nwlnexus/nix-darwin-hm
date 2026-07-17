import { describe, expect, test } from "bun:test";
import { isPublishableWikiRel } from "./strip-side-effects";

describe("isPublishableWikiRel", () => {
  const publishable = [
    "Architecture.md",
    "overview.md",
    "services/api/overview.md",
    "docs/tech-inventory.md",
  ];

  const nonPublishable = [
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "claude.md",
    ".github/workflows/openwiki-update.yml",
    ".github/workflows/openwiki-sync.yml",
    "README.txt",
    "package.json",
    "wiki/.git/config",
    "path/.git/HEAD",
    "AGENTS.md\\nested",
  ];

  test.each(publishable)("accepts %s", (rel) => {
    expect(isPublishableWikiRel(rel)).toBe(true);
  });

  test.each(nonPublishable)("rejects %s", (rel) => {
    expect(isPublishableWikiRel(rel)).toBe(false);
  });

  test("normalizes backslashes before matching", () => {
    expect(isPublishableWikiRel("services\\api\\overview.md")).toBe(true);
    expect(isPublishableWikiRel(".github\\workflows\\openwiki-update.yml")).toBe(false);
  });
});
