import { test, expect } from "bun:test";
import { commitToBranch, isMissingLabelError } from "./git-pr";
import { checkout } from "./checkout";
import { packChanged } from "./pack";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { $ } from "bun";

async function setupBaseRepo(): Promise<{
  root: string; bare: string; dir: string;
  target: { owner: string; name: string; slug: string; sshHost: string; originUrl: string; defaultBranch: string; packPath: string; branch: string; group: string };
}> {
  const root = mkdtempSync(join(tmpdir(), "gp-"));
  const bare = join(root, "origin.git");
  await $`git init -q --bare ${bare}`;
  const dir = join(root, "clone");
  await $`git clone -q ${bare} ${dir}`;
  await $`git -C ${dir} config user.email t@t`;
  await $`git -C ${dir} config user.name t`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  writeFileSync(join(dir, "CLAUDE.md"), "OLD CLAUDE");
  writeFileSync(join(dir, "AGENTS.md"), "OLD AGENTS");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false commit -qm base`;
  await $`git -C ${dir} push -q origin HEAD:main`;

  const target = {
    owner: "acme", name: "widget", slug: "acme/widget", sshHost: "github.com",
    originUrl: bare, defaultBranch: "main", packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack", group: "personal",
  };
  return { root, bare, dir, target };
}

const STAGE_FILES = [".llm/repomix.xml", ".gitignore", "CLAUDE.md", "AGENTS.md"];

// Regression coverage for the bug this file fixes: the PR gate used to be
// `if (!packChanged(...).changed) skip` in src/index.ts, which meant
// commitToBranch was only ever invoked when the pack's content hash moved.
// A graph-only refresh (pack byte-identical, CLAUDE.md rewritten by the
// gitnexus graph stage) was silently dropped: work happened, files changed
// in the cached checkout, and nothing was ever committed or PR'd.
//
// Proof this was real: with the pack-hash-only gate, `gate.changed` is
// false for a graph-only change, so `if (gate.changed) commitToBranch(...)`
// never runs commitToBranch at all — confirmed by running this scenario
// against the pre-fix code (commitToBranch had no gating of its own; the
// only gate lived in index.ts and it looked at the pack hash exclusively).
//
// The fix generalizes the gate to live inside commitToBranch itself: stage
// pack + .gitignore + CLAUDE.md + AGENTS.md, then commit/push iff there is
// any staged diff against base — regardless of which file(s) changed.
test("graph-only CLAUDE.md change (pack unchanged) still produces a commit", async () => {
  const { dir, target, bare } = await setupBaseRepo();

  // Pack regenerates identically; only CLAUDE.md was rewritten (as the
  // future graph stage does).
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  writeFileSync(join(dir, "CLAUDE.md"), "NEW CLAUDE FROM GRAPH STAGE");

  const gate = await packChanged(dir, target.packPath);
  expect(gate.changed).toBe(false); // pack itself is unchanged

  const result = await commitToBranch(dir, target as any, target.defaultBranch, STAGE_FILES);
  expect(result.committed).toBe(true);

  const show = await $`git -C ${bare} show automation/repomix-pack:CLAUDE.md`.text();
  expect(show.trim()).toBe("NEW CLAUDE FROM GRAPH STAGE");
});

test("pack-only change produces a commit", async () => {
  const { dir, target } = await setupBaseRepo();
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK v2");
  // CLAUDE.md / AGENTS.md left identical to base.

  const result = await commitToBranch(dir, target as any, target.defaultBranch, STAGE_FILES);
  expect(result.committed).toBe(true);
});

test("both pack and graph files changed produces exactly one commit/branch", async () => {
  const { dir, target, bare } = await setupBaseRepo();
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK v2");
  writeFileSync(join(dir, "CLAUDE.md"), "NEW CLAUDE");
  writeFileSync(join(dir, "AGENTS.md"), "NEW AGENTS");

  const result = await commitToBranch(dir, target as any, target.defaultBranch, STAGE_FILES);
  expect(result.committed).toBe(true);

  // Both files land in ONE commit on top of base, not one commit per file.
  // (`branch --list <exact-name>` could only ever return 0 or 1, so counting
  // its output asserted nothing beyond "the branch exists".)
  const ahead = (await $`git -C ${bare} rev-list --count main..automation/repomix-pack`.text()).trim();
  expect(ahead).toBe("1");
});

test("no changes at all: nothing is committed or pushed (no PR, no notification)", async () => {
  const { dir, target, bare } = await setupBaseRepo();
  // Nothing modified: pack, CLAUDE.md, AGENTS.md all identical to base.

  const result = await commitToBranch(dir, target as any, target.defaultBranch, STAGE_FILES);
  expect(result.committed).toBe(false);

  const branches = await $`git -C ${bare} branch`.text();
  expect(branches).not.toContain("automation/repomix-pack"); // no push happened
});

// Regression coverage for the stale-base bug. Every other test in this file
// builds a FRESH clone, where local `main` == `origin/main` by construction —
// so it structurally cannot see this. Only a *persistent* cacheRoot reused
// across sweeps (which is exactly how production runs) exposes it:
//
//   checkout() does `fetch` + `reset --hard origin/<default>`, and reset only
//   moves the branch HEAD is currently on. After sweep 1, commitToBranch has
//   left HEAD on automation/repomix-pack, so refs/heads/main is never advanced
//   again — it stays pinned at the original clone commit forever.
//
// Pre-fix, commitToBranch branched off the bare ref `main` (i.e. the stale
// LOCAL refs/heads/main). So on the sweep right after the automation PR is
// merged — when nothing whatsoever has changed and the pack is byte-identical
// — the gate still saw a diff, force-pushed, opened an empty PR and fired
// Slack, and did so on every subsequent sweep, forever. Worse, the branch was
// cut from stale main, so the PR reverted unrelated upstream commits.
//
// The fix branches off `origin/<base>` — the true remote state.
test("second sweep on a persistent cache after the PR is merged: no commit", async () => {
  const { root, bare, target } = await setupBaseRepo();
  const cacheRoot = join(root, "cache");

  // Sweep 1: the source drifted, so the pack regenerates differently.
  const first = await checkout(target as any, cacheRoot);
  writeFileSync(join(first.dir, ".llm/repomix.xml"), "PACK v2");
  const run1 = await commitToBranch(first.dir, target as any, first.defaultBranch, STAGE_FILES);
  expect(run1.committed).toBe(true);

  // A human merges the automation PR: origin/main now carries the new pack.
  await $`git -C ${bare} update-ref refs/heads/main refs/heads/automation/repomix-pack`;

  // Sweep 2: same cacheRoot (persists by design). Nothing in the world has
  // changed, so repomix reproduces a byte-identical pack.
  const second = await checkout(target as any, cacheRoot);
  expect(second.dir).toBe(first.dir); // same cached checkout, reused
  writeFileSync(join(second.dir, ".llm/repomix.xml"), "PACK v2");

  const run2 = await commitToBranch(second.dir, target as any, second.defaultBranch, STAGE_FILES);
  expect(run2.committed).toBe(false); // nothing changed => no PR, no Slack
});

test("missing CLAUDE.md/AGENTS.md in the repo is not an error", async () => {
  const root = mkdtempSync(join(tmpdir(), "gp-"));
  const bare = join(root, "origin.git");
  await $`git init -q --bare ${bare}`;
  const dir = join(root, "clone");
  await $`git clone -q ${bare} ${dir}`;
  await $`git -C ${dir} config user.email t@t`;
  await $`git -C ${dir} config user.name t`;
  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  // Deliberately no CLAUDE.md / AGENTS.md in this repo.
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false commit -qm base`;
  await $`git -C ${dir} push -q origin HEAD:main`;

  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK v2");
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget", sshHost: "github.com",
    originUrl: bare, defaultBranch: "main", packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack", group: "personal",
  };
  const result = await commitToBranch(dir, target as any, "main", STAGE_FILES);
  expect(result.committed).toBe(true);
  expect(existsSync(join(dir, "CLAUDE.md"))).toBe(false);
});

test("commits pack to deterministic branch and pushes to origin", async () => {
  const root = mkdtempSync(join(tmpdir(), "gp-"));
  const bare = join(root, "origin.git");
  await $`git init -q --bare ${bare}`;
  const dir = join(root, "clone");
  await $`git clone -q ${bare} ${dir}`;
  await $`git -C ${dir} config user.email t@t`;
  await $`git -C ${dir} config user.name t`;
  writeFileSync(join(dir, "seed"), "1");
  await $`git -C ${dir} add -A`;
  await $`git -C ${dir} -c commit.gpgsign=false commit -qm seed`;
  await $`git -C ${dir} push -q origin HEAD:main`;

  mkdirSync(join(dir, ".llm"), { recursive: true });
  writeFileSync(join(dir, ".llm/repomix.xml"), "PACK");
  const target = {
    owner: "acme", name: "widget", slug: "acme/widget", sshHost: "github.com",
    originUrl: bare, defaultBranch: "main", packPath: ".llm/repomix.xml",
    branch: "automation/repomix-pack", group: "personal",
  };
  await commitToBranch(dir, target as any, "main", [".llm/repomix.xml"]);

  const branches = await $`git -C ${bare} branch`.text();
  expect(branches).toContain("automation/repomix-pack");
  const show = await $`git -C ${bare} show automation/repomix-pack:.llm/repomix.xml`.text();
  expect(show.trim()).toBe("PACK");
});

test("isMissingLabelError detects label-not-found gh output", () => {
  expect(isMissingLabelError('label "automation" not found for nwlnexus/foo')).toBe(true);
  expect(isMissingLabelError("repository not found")).toBe(true);
  expect(isMissingLabelError("permission denied")).toBe(false);
  expect(isMissingLabelError("HTTP 422: Validation Failed")).toBe(false);
});
