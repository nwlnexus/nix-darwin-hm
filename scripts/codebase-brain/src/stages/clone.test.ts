import { describe, expect, test } from "bun:test";
import { cloneUrl } from "./clone";
import type { JobContext } from "../types";

const base = {
  owner: "nwlnexus",
  repo: "moneta",
} as JobContext;

describe("cloneUrl", () => {
  test("public URL when no token", () => {
    expect(cloneUrl(base, {})).toBe("https://github.com/nwlnexus/moneta.git");
  });

  test("embeds GH_TOKEN as x-access-token", () => {
    expect(cloneUrl(base, { GH_TOKEN: "gho_test" })).toBe(
      "https://x-access-token:gho_test@github.com/nwlnexus/moneta.git",
    );
  });

  test("GITHUB_TOKEN fallback", () => {
    expect(cloneUrl(base, { GITHUB_TOKEN: "ghs_test" })).toBe(
      "https://x-access-token:ghs_test@github.com/nwlnexus/moneta.git",
    );
  });

  test("GH_TOKEN wins over GITHUB_TOKEN", () => {
    expect(cloneUrl(base, { GH_TOKEN: "a", GITHUB_TOKEN: "b" })).toBe(
      "https://x-access-token:a@github.com/nwlnexus/moneta.git",
    );
  });
});
