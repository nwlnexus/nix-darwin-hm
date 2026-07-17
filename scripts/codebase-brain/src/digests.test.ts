import { describe, expect, test } from "bun:test";
import { sha256Hex, shouldSkipLlm, TEMPLATE_VERSION } from "./digests";

describe("digests", () => {
  test("sha256Hex is stable", () => {
    expect(sha256Hex("abc")).toBe(sha256Hex("abc"));
    expect(sha256Hex("abc")).not.toBe(sha256Hex("abd"));
  });

  test("shouldSkipLlm when all digests match", () => {
    const d = {
      packHash: "a",
      graphDigest: "b",
      sbomDigest: "c",
      templateVersion: TEMPLATE_VERSION,
    };
    expect(shouldSkipLlm(d, d)).toBe(true);
    expect(shouldSkipLlm(d, { ...d, packHash: "x" })).toBe(false);
  });
});
