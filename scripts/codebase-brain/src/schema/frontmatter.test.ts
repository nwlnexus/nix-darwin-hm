import { describe, expect, test } from "bun:test";
import { NwlDocSchema } from "./frontmatter";

describe("NwlDocSchema", () => {
  test("requires nwl extensions", () => {
    const ok = NwlDocSchema.safeParse({
      type: "Repository Overview",
      title: "moneta",
      description: "x",
      tags: ["a"],
      docType: "overview",
      repo: "moneta",
      owner: "nwlnexus",
      slug: "moneta/overview",
      source: {
        sha: "abc",
        packHash: "sha256:1",
        graphDigest: "sha256:2",
        graphUri: "r2://graphs/nwlnexus/moneta/abc",
        templateVersion: "openwiki-0.2",
      },
      brainPath: "docs/codebases/moneta/overview.md",
      status: "generated",
    });
    expect(ok.success).toBe(true);
  });
});
