import { test, expect } from "bun:test";
import { loadTargets } from "./config";
import { writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";

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

[repo."dtlr/marquee"]
graph = false
`;

function fixture(): string {
  const dir = mkdtempSync(join(tmpdir(), "repos-"));
  const p = join(dir, "repos.toml");
  writeFileSync(p, TOML);
  return p;
}

test("a duplicate repo NAME across groups is refused, loudly, at load", () => {
  // The gitnexus registry alias is the BARE NAME, and pruneGraphs deletes
  // registry entries BY NAME. Two owners with a same-named repo would share one
  // alias and could prune each other's entry. All 11 names are unique today;
  // this makes sure a 12th can never quietly collide. It must fail at LOAD --
  // before anything is analyzed, registered or deleted.
  const dir = mkdtempSync(join(tmpdir(), "repos-dup-"));
  const p = join(dir, "repos.toml");
  writeFileSync(
    p,
    `
[groups.personal]
base_dir = "~/projects/personal"
ssh_host = "github.com"
owner = "nwlnexus"
repos = ["widget"]

[groups.work]
base_dir = "~/projects/work"
ssh_host = "github.com-work"
owner = "dtlr"
repos = ["widget"]
`,
  );
  expect(() => loadTargets(p)).toThrow(/duplicate repo name "widget"/i);
  // ...and narrowing the sweep does not narrow the check: the collision is a
  // property of the CONFIG, not of one run's filter.
  expect(() => loadTargets(p, { group: "personal" })).toThrow(/duplicate/i);
  expect(() => loadTargets(p, { only: ["nwlnexus/widget"] })).toThrow(/duplicate/i);
});

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

test("graph defaults to true when absent", () => {
  const targets = loadTargets(fixture());
  const sdk = targets.find((t) => t.name === "olympus-sdk")!;
  expect(sdk.graph).toBe(true);
});

test("explicit graph = false is honored", () => {
  const targets = loadTargets(fixture());
  const marquee = targets.find((t) => t.name === "marquee")!;
  expect(marquee.graph).toBe(false);
});

test("devClonePath expands ~ and composes base_dir + name for the personal group", () => {
  const targets = loadTargets(fixture());
  const moneta = targets.find((t) => t.name === "moneta")!;
  expect(moneta.devClonePath).toBe(join(homedir(), "projects/personal/moneta"));
});

test("devClonePath expands ~ and composes base_dir + name for the work group", () => {
  const targets = loadTargets(fixture());
  const marquee = targets.find((t) => t.name === "marquee")!;
  expect(marquee.devClonePath).toBe(join(homedir(), "projects/work/marquee"));
});
