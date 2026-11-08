# Progress: nwlnexus/olympus-sdk#860 memory-compile.service failing (brain lint) and userborn restart error

<!-- long-task progress file; removed in the final commit before merge. No wikilinks in this file (lint scans it). -->

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/860`
- **Branch / worktree:** part 1 `fix/860-inbox-title-collision` (second-brain, merged as second-brain#26); part 2 `fix/860-userborn-wrappers-order` in `~/projects/personal/.worktrees/nix-darwin-hm-860`
- **Session:** `personal-olympus-sdk-860` on `ai-agent-host`; registry id `679e717b-7105-4872-8eb2-6cfb73343528`
- **Started:** 2026-11-08 17:30 EST · **Turn cap:** 60
- **PRs:** https://github.com/nwlnexus/second-brain/pull/26 (merged 2026-11-08 22:38Z), https://github.com/nwlnexus/nix-darwin-hm/pull/182

## Goal

```text
/goal memory-compile.service runs green (systemctl --user start memory-compile succeeds, or the next timer run does), with the cause fixed and a test where the repo has one; a scripts/linux-switch.sh run on ai-agent-host logs no userborn error, or the error is explained and accepted in a comment on olympus-sdk#860 (the host switch is the owner's). Checks: (second-brain) node scripts/test-lint.mjs exit 0; node --test scripts/compile/test/*.test.mjs exit 0 including the title-collision tests; node scripts/lint-brain.mjs exit 0; after merge systemctl --user start memory-compile exit 0 and systemctl --user is-failed memory-compile prints inactive; userborn: fix merged in nix-darwin-hm with an eval test, or an explanation comment on #860. Progress file docs/progress/2026-11-08-860-inbox-title-collision.md is current. Or stop after 60 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `node scripts/test-lint.mjs` | exit 0, names the duplicate-title rule | PASS | b908cd3 |
| 2 | `node --test scripts/compile/test/*.test.mjs` | exit 0, title-collision test passes | PASS (22/22) | b908cd3 |
| 3 | `node scripts/lint-brain.mjs` | exit 0 | PASS | b908cd3 |
| 4 | `systemctl --user start memory-compile; systemctl --user is-failed memory-compile` (after merge) | exit 0; `inactive` | not run | |
| 5 | userborn: nix-darwin-hm fix + eval test merged, or explanation comment on #860 | link | PR nix-darwin-hm#182 open; host switch is the owner's | nix-darwin-hm fix/860-userborn-wrappers-order |

## Plan

### Blast radius

Blast radius: no index (second-brain is not indexed by GitNexus; `list_repos` lists only olympus-sdk and nix-darwin-hm). Text search: `importInbox` has one caller, `run` in `scripts/compile/compile.mjs:472`; `scripts/lint-brain.mjs` is run by the compile's `lint()` (`compile.mjs:262`), `scripts/test-lint.mjs` and CI `lint.yml`.

### Root cause (part 1)

The 2026-11-08 run imported an untracked proposal from the /brain checkout, `raw/_inbox/auto-memory-ai-agent-host-feedback-automerge-all-repos-f61916bf.md`: a new revision of an auto-memory note whose earlier revision (`...-dcb7e498.md`, status ingested) is already on main. Both carry the title `Auto-memory (feedback): feedback-automerge-all-repos`. `loadPages` maps each lowercased title to one page, last one wins, so the wiki page's link to that title moved to the new note and the ingested old one became "not referenced by any wiki page". Every note in the run was then rejected and nothing published; the untracked copy stays in the checkout (removed only after a publish), so every night fails the same way.

### Steps

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | `importInbox`: give an imported note whose title is already a link name in the clone (or of an earlier import) a unique title, `<title> (<rev>)` | opus | main | done |
| 2 | `lint-brain`: new rule, two raw/wiki pages with the same title, plus fixture in test-lint | opus | main | done |
| 3 | Tests: compile e2e test with a revised proposal colliding with an ingested source | opus | main | done |
| 4 | Userborn: override suid-sgid-wrappers.after + eval test (nix-darwin-hm#182) | opus | subagent `userborn-investigator`, then main | done |
| 5 | PR, CI, verifier, merge; then `systemctl --user start memory-compile` | opus | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 17:35 | `journalctl --user -u memory-compile` (04:58 run) | - | `[compile] imported 4 inbox proposal(s)` … `rejected: raw/_inbox/auto-memory-ai-agent-host-feedback-automerge-all-repos-f61916bf.md: lint: … dcb7e498.md: ingested source not referenced by any wiki page` | |
| 17:37 | `node scripts/lint-brain.mjs .` on origin/main clone | 0 | `✓ brain lint: 181 pages, no issues` | 90a62c8 |
| 18:05 | `node scripts/test-lint.mjs` | 0 | `✓ lint-brain self-test passed` | step 1-3 commit |
| 18:05 | `node --test scripts/compile/test/*.test.mjs` | 0 | `ℹ tests 22` `ℹ pass 22` `ℹ fail 0` | step 1-3 commit |
| 18:06 | same, `--test-name-pattern="revised proposal"` with the compile.mjs change reverted | 1 | `ℹ pass 0` `ℹ fail 1` (the test catches the bug) | - |
| 18:08 | import simulation of the 4 real untracked notes from the /brain checkout + `node scripts/lint-brain.mjs .` | 0 | `renamed …-f61916bf.md -> Auto-memory (feedback): feedback-automerge-all-repos (f61916bf)` (also 44565600, 17c6afb0); `✓ brain lint: 186 pages, no issues` | - |

| 18:25 | claim-verifier on checks 1-3 (second-brain#26 at b908cd3) | - | `VERDICT: PASS` | b908cd3 |
| 18:30 | nix-darwin-hm `nix eval --impure --json --expr 'import ./tests { }'` | 0 | `[]`; with the override reverted `[{"expected":[],"name":"testNoUnitReferencesUserborn","result":["suid-sgid-wrappers"]}]` | nix-darwin-hm#182 |
| 18:31 | gitnexus `detect_changes` nix-darwin-hm unstaged | - | `changed_count 0, changed_files 2, risk_level low` (nix files carry no indexed symbols) | nix-darwin-hm#182 |
| 18:52 | `systemctl --user start memory-compile` after second-brain#26 | 1 | `imported as "Auto-memory (feedback): feedback-automerge-all-repos (f61916bf)"` (fix works) but `duplicate title 'Compile draft 2026-11-08 Olympus SDK'` on the run's own drafts (rule 4b regression) | second-brain#26 |
| 18:58 | second-brain#27: rule 4b only with a wiki page or ingested source in the group; draft titles carry the counter; `node --test …` 22/22, `test-lint` ✓ | 0 | `ℹ pass 22` `ℹ fail 0` | second-brain#27 |

## Decisions

- 2026-11-08: Fix in the compile importer (the only automated path into the wiki) plus a lint rule, not in the olympus-memory sync's title format. Why: any proposal source can collide; lint makes a hand ingest of a duplicate fail loudly with the real cause.
- 2026-11-08: Lint rule covers title-vs-title only. Why: existing alias collisions on main (`olympus`, `olympus k3s`, `unified cluster`, `compute-hub`) would make a wider rule fail main.

- 2026-11-08: Root cause also covers notes 44565600 and 17c6afb0 (revisions colliding with ingested titles); the import simulation renamed all three.
- 2026-11-08: Userborn (part 2) is harmless engine noise caused by upstream's unconditional After=userborn.service on suid-sgid-wrappers; fixed in nix-darwin-hm#182 with mkOverride 40 (upstream uses mkForce).
- 2026-11-08: Rule 4b narrowed (second-brain#27) after it rejected a run's own same-titled compile drafts; pending notes are never linked.

## Blocked-on

- none

## Next

1. Merge second-brain#27 after verifier PASS; re-run `systemctl --user start memory-compile`; merge nix-darwin-hm#182; owner runs the host switch.
