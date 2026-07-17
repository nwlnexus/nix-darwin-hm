import { describe, expect, test } from "bun:test";
import { buildContext } from "./index";

describe("buildContext", () => {
  test("defaults phase to all", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc"]);
    expect(ctx.phase).toBe("all");
  });

  test("accepts --phase 1", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "1"]);
    expect(ctx.phase).toBe("1");
  });

  test("accepts --phase 2", () => {
    const ctx = buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "2"]);
    expect(ctx.phase).toBe("2");
  });

  test("throws when --repo is missing", () => {
    expect(() => buildContext(["--sha", "abc"])).toThrow("--repo and --sha are required");
  });

  test("throws for invalid --phase", () => {
    expect(() =>
      buildContext(["--repo", "moneta", "--sha", "abc", "--phase", "bogus"]),
    ).toThrow("--phase must be 1 | 2 | all");
  });
});
