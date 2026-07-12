import { test, expect } from "bun:test";
import { StagingSink } from "./sink";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

test("StagingSink writes pack + manifest", async () => {
  const root = mkdtempSync(join(tmpdir(), "brain-"));
  const sink = new StagingSink(root);
  await sink.write(new TextEncoder().encode("PACK"), {
    slug: "acme/widget", owner: "acme", name: "widget",
    commit: "deadbeef", hash: "abc123", bytes: 4, ts: "2026-07-12T00:00:00Z",
  });
  expect(existsSync(join(root, "acme/widget.xml"))).toBe(true);
  const manifest = JSON.parse(readFileSync(join(root, "acme/widget.json"), "utf8"));
  expect(manifest.slug).toBe("acme/widget");
  expect(manifest.hash).toBe("abc123");
});
