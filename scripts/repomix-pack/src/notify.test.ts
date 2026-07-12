import { test, expect } from "bun:test";
import { buildSlackPayload } from "./notify";

test("payload includes repo, action verb, and PR link", () => {
  const p = buildSlackPayload({
    slug: "nwlnexus/olympus-sdk", base: "main",
    prUrl: "https://github.com/nwlnexus/olympus-sdk/pull/9",
    created: true, bytes: 12345,
  });
  const text = JSON.stringify(p);
  expect(text).toContain("nwlnexus/olympus-sdk");
  expect(text).toContain("opened");
  expect(text).toContain("/pull/9");
});

test("updated PR uses 'updated' verb", () => {
  const p = buildSlackPayload({
    slug: "a/b", base: "main", prUrl: "u", created: false, bytes: 1,
  });
  expect(JSON.stringify(p)).toContain("updated");
});
