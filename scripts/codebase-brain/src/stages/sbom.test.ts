import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseSbomDigest } from "./sbom";

describe("sbom", () => {
  test("parseSbomDigest hashes file contents", async () => {
    const dir = await mkdtemp(join(tmpdir(), "sbom-"));
    const p = join(dir, "sbom.cdx.json");
    await writeFile(p, JSON.stringify({ bomFormat: "CycloneDX", components: [] }));
    const d = await parseSbomDigest(p);
    expect(d.startsWith("sha256:")).toBe(true);
  });
});
