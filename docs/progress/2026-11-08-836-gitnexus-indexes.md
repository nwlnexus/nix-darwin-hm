# Progress: nwlnexus/olympus-sdk#836 HW18 GitNexus indexes for every repo that claims one (no-churn)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/836`
- **Branch / worktree:** `chore/836-gitnexus-indexes` in `~/projects/personal/.worktrees/<repo>-836` (nix-darwin-hm, olympus-gitops, olympus-infra, olympus-tailnet); this file lives on the nix-darwin-hm branch
- **Session:** `personal-olympus-sdk-836` on `ai-agent-host`; registry id `b6c508d2-5263-4e0c-bb22-5f83e9f9af80`
- **Started:** 2026-11-08 16:30 local · **Turn cap:** 60
- **Draft PRs:** olympus-gitops#248, olympus-infra#130, olympus-tailnet#16, nix-darwin-hm: not yet

## Goal

```text
/goal Every repo that claims a GitNexus index has one at its origin/main HEAD, the claim appears only in indexed repos, a commit in each indexed repo leaves git status clean and the index at HEAD, and the PRs are merged. Checks: registry lastCommit == origin/main for olympus-sdk and nix-darwin-hm; grep -l "indexed by GitNexus" */CLAUDE.md */AGENTS.md lists only olympus-sdk and nix-darwin-hm; after a commit, git status --short empty and gitnexus status up-to-date; gh pr view state MERGED for each PR. Progress file current until its removal. Or stop after 60 turns.
```

## Done-when checks

Run from `~/projects/personal`.

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `for r in olympus-sdk nix-darwin-hm; do jq -r --arg p "$PWD/$r" '.[]\|select(.path==$p)\|.lastCommit' ~/.gitnexus/registry.json; git -C $r rev-parse origin/main; done` | each pair of lines equal | not run | |
| 2 | `grep -l "indexed by GitNexus" */CLAUDE.md */AGENTS.md` | only `nix-darwin-hm/*` and `olympus-sdk/*` | not run | |
| 3 | after a commit (or ff pull) in each indexed main checkout: `git -C <repo> status --short` and `(cd <repo> && gitnexus status)` | no tracked changes; `up-to-date` | not run | |
| 4 | `gh pr view <n> --repo nwlnexus/<repo> --json state -q .state` for each PR | `MERGED` | not run | |

## Plan

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Trial index-only build per repo, decide index vs remove claim | opus | main | done |
| 2 | olympus-tailnet: issue templates, then replace block with a repo guide | opus | main | done (PR #16) |
| 3 | olympus-gitops, olympus-infra: drop block + MUST rules, record why | opus | main | done (PR #248, #130) |
| 4 | nix-darwin-hm: refresh script + .githooks post-*, justfile recipes, --no-stats block, hygiene section | opus | main | todo |
| 5 | nix-darwin-hm: activation bootstraps declared repo indexes on every host | opus | main | todo |
| 6 | Registry and grep checks | haiku-level, run inline | main | todo |
| 7 | claim-verifier, ready, automerge, pull main, no-churn check | sonnet (verifier) | subagent | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 16:35 | `gitnexus analyze --index-only` in nix-darwin-hm | 0 | `1,220 nodes \| 1,771 edges \| 10 clusters \| 29 flows` (75 Function, 24 Const) | 6e540e9 |
| 16:35 | same in olympus-gitops | 0 | `468 nodes \| 466 edges \| 1 clusters \| 0 flows` (2 Function, 8 Variable) | fc5f025 |
| 16:35 | same in olympus-infra | 0 | `869 nodes \| 861 edges \| 0 clusters \| 0 flows` (File/Folder/Section only) | 39a1fd3 |
| 16:35 | same in olympus-tailnet | 0 | `17 nodes \| 13 edges \| 0 clusters \| 0 flows` | e14e5ce |
| 16:35 | same in agent-plugins | 0 | `83 nodes \| 82 edges \| 0 clusters \| 0 flows` | ae7fc41 |
| 16:35 | same in olympus-memory | 0 | `150 nodes \| 231 edges \| 2 clusters \| 0 flows` (8 Function, 4 Route) | bc1223e |
| 16:37 | `gitnexus clean -f` in the five small repos; `gitnexus list` | 0 | `olympus-sdk`, `nix-darwin-hm` | |

## Decisions

- 2026-11-08: index nix-darwin-hm (75 functions, 29 flows in its TypeScript tooling) and keep olympus-sdk. Do not index olympus-gitops, olympus-infra, olympus-tailnet (YAML/Ansible/HuJSON: GitNexus finds 0 to 2 code symbols), agent-plugins (shell and markdown: 0 symbols) or olympus-memory (8 functions). Remove the claim and MUST rules where present and say why in the repo docs. agent-plugins and olympus-memory never claimed an index, so they get no change.
- 2026-11-08: olympus-sdk needs no change for #836: it is indexed and already has the husky refresh hooks and `gitnexus:index` / `gitnexus:refresh-docs`.

## Blocked-on

- none

## Next

1. nix-darwin-hm step 4 (hooks, recipes, --no-stats block, hygiene section) in this worktree.
