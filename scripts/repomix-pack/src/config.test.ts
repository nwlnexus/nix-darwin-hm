import { test, expect } from "bun:test";
import { loadTargets } from "./config";
import { writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const TOML = `
[defaults]
pack_path = ".llm/repomix.xml"
branch = "automation/repomix-pack"

[groups.personal]
base_dir = "~/projects/personal"
ssh_host = "github.com"
owner = "nwlnexus"
repos = ["olympus-sdk", "moneta"]

[groups.work]
base_dir = "~/projects/work"
ssh_host = "github.com-work"
owner = "dtlr"
repos = ["marquee"]
`;

function fixture(): string {
  const dir = mkdtempSync(join(tmpdir(), "repos-"));
  const p = join(dir, "repos.toml");
  writeFileSync(p, TOML);
  return p;
}

test("loads all targets with derived fields", () => {
  const targets = loadTargets(fixture());
  expect(targets.length).toBe(3);
  const sdk = targets.find((t) => t.name === "olympus-sdk")!;
  expect(sdk.slug).toBe("nwlnexus/olympus-sdk");
  expect(sdk.originUrl).toBe("git@github.com:nwlnexus/olympus-sdk.git");
  expect(sdk.packPath).toBe(".llm/repomix.xml");
  expect(sdk.branch).toBe("automation/repomix-pack");
});

test("filters by group", () => {
  const targets = loadTargets(fixture(), { group: "work" });
  expect(targets.map((t) => t.slug)).toEqual(["dtlr/marquee"]);
  expect(targets[0].sshHost).toBe("github.com-work");
});

test("filters by explicit slug list", () => {
  const targets = loadTargets(fixture(), { only: ["nwlnexus/moneta"] });
  expect(targets.map((t) => t.slug)).toEqual(["nwlnexus/moneta"]);
});
