# Linux Agent Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage headless Ubuntu agent hosts (first: `ai-agent-host`, x86_64)
from this flake. system-manager owns the OS layer and standalone home-manager
owns the user environment. Each host gets per-account Claude Code and Codex
commands plus always-on Remote Control services. The macOS hosts must not
change.

**Architecture:** `flake.nix` discovers `hosts/linux/*.nix` and generates two
outputs per host:

- `homeConfigurations."nwilliams-lucas@<host>"`, through a new standalone entry
  module (`home/standalone.nix`) that reuses `home/`;
- `systemConfigs.<host>`, through `system/linux/`.

Two new options gate everything Linux-specific: `d.apps.onepassword.gui` and
`d.agentHost.enable`. A config-snapshot test proves the darwin output is
unchanged at every step.

**Tech Stack:** Nix flakes, flake-utils-plus, home-manager release-26.05,
numtide system-manager v1.1.0, op-secrets (`nwlnexus/nix-op-secrets`), systemd
user units, bash, `just`.

**Spec:** `docs/superpowers/specs/2026-09-30-linux-agent-host-design.md`

## Global Constraints

- **Primary user:** `nwilliams-lucas`. State version `26.05`. Theme `catppuccin`.
- **Host:** `ai-agent-host`, platform `x86_64-linux`, Ubuntu 26.04.1.
- **Accounts:** `personal` → `/home/nwilliams-lucas/projects/personal` and
  `work` → `/home/nwilliams-lucas/projects/work`, for both Claude Code and Codex.
- **Config directories:** Claude Code uses `CLAUDE_CONFIG_DIR=~/.claude-<acct>`;
  Codex uses `CODEX_HOME=~/.codex-<acct>`.
- **Default account** outside both trees: `personal`.
- **Token files:** `~/.config/personal/1penv` and `~/.config/work/1penv`,
  directories `0700`, files `0600`.
- **Native installs:** Claude Code and Codex stay as installed by their own
  installers, in `~/.local/bin`. Nix only wraps them.
- **`op`:** keep the apt `1password-cli` beta. Don't add `pkgs._1password-cli`
  to `home.packages` on Linux.
- **Not managed:** the sshd service and Tailscale. Only add an sshd config
  drop-in, `/etc/ssh/sshd_config.d/05-nix-hardening.conf`.
- **system-manager:** pinned to `github:numtide/system-manager/v1.1.0`, with
  `inputs.nixpkgs.follows = "nixpkgs"` (unstable, which system-manager is
  tested against).
- **Darwin must be unchanged:** `just check-darwin` must print no diff at every
  commit.
- **Formatting and tests:** run `nix fmt` before every commit. `just test` must
  print `[]`.
- **Commit trailer:** end every commit message with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **PR body footer:**
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- **Merging:** GitHub can't auto-merge here because `main` has no protection or
  ruleset. "Ready" means `just test` and `just check-darwin` pass. Then run
  `gh pr merge <n> --squash --delete-branch`, remove the worktree, delete the
  local branch, and fast-forward the main checkout at
  `/Volumes/REALTEK/projects/personal/nix-darwin-hm`.
- **New files:** evaluation uses `builtins.getFlake`, which only sees files git
  knows about. `git add` every new file *before* running `just test`.

**PR order differs from the spec on purpose.** The standalone output ships
first (PR 1) and the portability fixes second (PR 2). The portability fixes
can only be tested against a Linux output, so that output has to exist first.

| PR | Branch | Tasks |
|---|---|---|
| 1 | `feat/standalone-home-manager` | 1, 2, 3 |
| 2 | `fix/linux-home-portability` | 4, 5 |
| 3 | `feat/system-manager-agent-host` | 6, 7 |
| 4 | `feat/agent-host-tooling` | 8, 9 |
| on-host | none | 10 |

## Review Focus

1. **A Remote Control unit before its account is logged in.** It must be
   *skipped* on its `ExecCondition`, not crash-loop. Pinned by
   `testClaudeCondition`/`testCodexCondition` (Task 8) and the on-host check in
   Task 10 step 6.
2. **A missing or wrong 1Password token file.** `home-manager switch` must fail
   loudly and name the secret, not half-apply. Pinned by
   `testEverySecretHasToken` (Task 5); Task 10 step 3 checks the error text.
3. **Working outside both project trees.** Plain `claude`/`codex` must use the
   `personal` account; inside `~/projects/work` they must use `work`. Pinned by
   `testDefaultAccount`, `testWorkDirenv` and `testPersonalDirenvNoWork`
   (Task 8).
4. **An sshd drop-in that doesn't validate.** The switch script must not reload
   sshd, so access is kept. Pinned by `testSwitchValidatesSshd` (Task 7).
5. **Re-running the bootstrap on a configured host.** It must change nothing.
   Pinned by `testBootstrapIdempotentGuards` (Task 7) and the second dry run
   in Task 10 step 4.

---

## PR 1: `feat/standalone-home-manager`

Set up the worktree once for Tasks 1–3:

```bash
cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git fetch -q origin && git worktree add -b feat/standalone-home-manager .claude/worktrees/standalone-hm origin/main
```

Work in `/Volumes/REALTEK/projects/personal/nix-darwin-hm/.claude/worktrees/standalone-hm`
for Tasks 1–3.

### Task 1: Evaluation test harness and darwin snapshot gate

**Files:**
- Create: `tests/lib/hm-snapshot.nix`
- Create: `tests/lib/darwin-snapshot.nix`
- Create: `tests/default.nix`
- Create: `tests/harness.nix`
- Modify: `justfile` (append three recipes)

**Interfaces:**
- Produces:
  - `import ./tests { }` evaluates to a list of failed tests (`[]` means all
    pass).
  - Each suite is a function `{ flake, lib }: { test<Name> = { expr; expected; }; … }`.
  - `tests/lib/hm-snapshot.nix` is `{ lib, hm }: <attrset>`, where `hm` is an
    evaluated home-manager `config`.
  - Recipes `just test`, `just darwin-snapshot [host] [ref]` and
    `just check-darwin [host] [ref]`.

- [ ] **Step 1: Write the snapshot helpers**

Create `tests/lib/hm-snapshot.nix`:

```nix
# A store-hash-free, JSON-serialisable snapshot of an evaluated home-manager
# config. Used to prove refactors don't change a host's output: the source
# path leaks into derivations (PROJECT_ROOT, nix.linkInputs), so drvPath
# comparisons change on every commit, but this snapshot doesn't.
{ lib, hm }:
let
  norm =
    s:
    lib.concatMapStrings (x: if builtins.isList x then "/nix/store/HASH-" else x) (
      builtins.split "/nix/store/[a-z0-9]{32}-" s
    );
  show = v: if v == null then null else norm (toString v);
  enabled = lib.filterAttrs (_: f: f.enable);
in
{
  files = lib.mapAttrs' (
    _: f:
    lib.nameValuePair f.target {
      text = if f.text == null then null else norm f.text;
      source = if f.text != null then null else show f.source;
      inherit (f) executable;
    }
  ) (enabled hm.home.file);
  xdg = lib.mapAttrs (_: f: if f.text == null then show f.source else norm f.text) (
    enabled hm.xdg.configFile
  );
  sessionVariables = lib.mapAttrs (_: show) hm.home.sessionVariables;
  sessionPath = map show hm.home.sessionPath;
  shellAliases = hm.home.shellAliases;
  packages = lib.sort lib.lessThan (map lib.getName hm.home.packages);
  activation = lib.mapAttrs (_: e: norm e.data) hm.home.activation;
  launchdAgents = lib.attrNames (lib.filterAttrs (_: a: a.enable) (hm.launchd.agents or { }));
  systemdUserServices = lib.attrNames (hm.systemd.user.services or { });
}
```

Create `tests/lib/darwin-snapshot.nix`:

```nix
# Snapshot of one darwin host: its home-manager config plus the system-level
# package and Homebrew lists. Compared across git refs by `just check-darwin`.
{
  flake,
  host,
  user ? "nwilliams-lucas",
}:
let
  lib = flake.inputs.nixpkgs.lib;
  cfg = flake.darwinConfigurations.${host}.config;
in
{
  home = import ./hm-snapshot.nix {
    inherit lib;
    hm = cfg.home-manager.users.${user};
  };
  systemPackages = lib.sort lib.lessThan (map lib.getName cfg.environment.systemPackages);
  homebrew = {
    brews = map (b: b.name) cfg.homebrew.brews;
    casks = map (c: c.name) cfg.homebrew.casks;
    inherit (cfg.homebrew) extraConfig;
  };
}
```

- [ ] **Step 2: Write the test runner and a first suite that must fail**

Create `tests/default.nix`:

```nix
# Evaluation tests. Run with `just test`; prints the failures, `[]` = pass.
# Each suite is `{ flake, lib }: { test<Name> = { expr; expected; }; }`.
{
  flake ? builtins.getFlake (toString ../.),
}:
let
  lib = flake.inputs.nixpkgs.lib;
  suites = [
    ./harness.nix
  ];
in
lib.debug.runTests (lib.foldl' (acc: f: acc // import f { inherit flake lib; }) { } suites)
```

Create `tests/harness.nix`. It deliberately asserts something false, so step 4
can prove the runner reports failures:

```nix
# Sanity checks for the test harness itself.
{ flake, lib }:
let
  snap = import ./lib/darwin-snapshot.nix {
    inherit flake;
    host = "NWL-MMINI";
  };
in
{
  testSnapshotHasNoStoreHashes = {
    expr = builtins.match ".*/nix/store/[a-z0-9]{32}-.*" (builtins.toJSON snap) == null;
    expected = false; # deliberately wrong; flipped to true in step 5
  };
}
```

- [ ] **Step 3: Add the `just` recipes**

Append to `justfile`:

```just
# Run the Nix evaluation tests in tests/ (prints failures; [] = all pass)
test:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(nix eval --impure --json --expr 'import ./tests { }')"
    echo "$out" | jq .
    [ "$out" = "[]" ]

# Print a normalized snapshot of a darwin host's evaluated config.
# With a ref, evaluates that git revision of this repo instead of the working tree.
darwin-snapshot host="NWL-MMINI" ref="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{ ref }}" ]; then
      # The main checkout (not a linked worktree) shares the object store.
      main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
      src="git+file://$main?rev=$(git rev-parse {{ ref }})"
    else
      src="$(pwd)"
    fi
    nix eval --impure --json --expr \
      "import ./tests/lib/darwin-snapshot.nix { flake = builtins.getFlake \"$src\"; host = \"{{ host }}\"; }" \
      | jq -S .

# Fail (and show the diff) if a darwin host's config differs from ref
check-darwin host="NWL-MMINI" ref="origin/main":
    #!/usr/bin/env bash
    set -euo pipefail
    diff -u <(just darwin-snapshot {{ host }} {{ ref }}) <(just darwin-snapshot {{ host }}) \
      && echo "darwin {{ host }}: unchanged vs {{ ref }}"
```

- [ ] **Step 4: Run the tests and watch the deliberate failure**

```bash
git add tests justfile && just test
```

Expected: exits non-zero and prints one failure whose `name` is
`testSnapshotHasNoStoreHashes`, with `"expected": false` and `"result": true`.

- [ ] **Step 5: Fix the assertion and re-run**

In `tests/harness.nix`, change the line to `expected = true;` and delete the
`# deliberately wrong…` comment.

```bash
just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`.

- [ ] **Step 6: Commit**

```bash
nix fmt && git add tests justfile && git commit -m "test: add evaluation test harness and darwin snapshot gate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: Move the home-manager side of `d.shell` into `home/shell.nix`

The standalone output needs `d.shell` without nix-darwin. Today the
home-manager-side option and how it's applied live inside `modules/shell.nix`,
a *system* module. This task makes that a plain home-manager module, which the
system module then imports. Darwin output must be unchanged.

**Files:**
- Create: `home/shell.nix`
- Modify: `modules/shell.nix` (whole file)

**Interfaces:**
- Produces: the home-manager module `home/shell.nix`. It defines
  `options.d.shell.{aliases (attrs), variables (attrs), sources (listOf str)}`
  and applies `home.shellAliases = aliases // <built-ins>` and
  `home.sessionVariables = variables`.

- [ ] **Step 1: Confirm the gate is green before refactoring**

```bash
just check-darwin
```

Expected: `darwin NWL-MMINI: unchanged vs origin/main`.

- [ ] **Step 2: Create `home/shell.nix`**

```nix
# Home-manager side of the `d.shell` convenience options: modules set
# d.shell.{aliases,variables,sources}; this applies them. Imported by the
# system module (modules/shell.nix) on nix-darwin/NixOS and directly by
# home/standalone.nix on standalone home-manager hosts.
{ config, lib, ... }:

with lib;

let
  cfg = config.d.shell;
in

{
  options.d.shell = {
    aliases = mkOption {
      type = types.attrs;
      default = { };
    };

    variables = mkOption {
      type = types.attrs;
      default = { };
    };

    sources = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
  };

  config = {
    home.sessionVariables = cfg.variables;
    home.shellAliases = cfg.aliases // {
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";

      clear = "tput reset";
      grep = "rg";
      mkdir = "mkdir -p";
    };
  };
}
```

- [ ] **Step 3: Rewrite `modules/shell.nix` to delegate**

Replace the whole file with:

```nix
{
  config,
  lib,
  user,
  ...
}:

with lib;

let
  cfg = config.d.shell;
  profiles = config.d.profiles;

  # FIXME: remove later
  cfgHome = config.home-manager.users.${user}.d.shell;
in

{
  # System-level d.shell. Values set here are forwarded into home-manager,
  # where home/shell.nix applies them alongside the hm-level definitions.
  options.d.shell = {
    enable = mkOption {
      type = types.bool;
      default = profiles.base.enable;
    };

    aliases = mkOption {
      type = types.attrs;
      default = { };
    };

    variables = mkOption {
      type = types.attrs;
      default = { };
    };

    sources = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
  };

  config = {
    # FIXME: remove later
    d.shell.sources = cfgHome.sources;

    d.hm = [
      ../home/shell.nix
      {
        d.shell.aliases = cfg.aliases;
        d.shell.variables = cfg.variables;
      }
    ];
  };
}
```

- [ ] **Step 4: Prove darwin is unchanged**

```bash
git add home/shell.nix && just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`. A diff in
`shellAliases` or `sessionVariables` means the merge order changed. Make sure
the built-in aliases are still merged *last* (`cfg.aliases // { … }`).

- [ ] **Step 5: Commit**

```bash
nix fmt && git add home/shell.nix modules/shell.nix && git commit -m "refactor: make the home-manager side of d.shell a standalone module

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Standalone home-manager output for `ai-agent-host`

**Files:**
- Create: `home/standalone.nix`
- Create: `home/linux-shell.nix`
- Create: `hosts/linux/ai-agent-host.nix`
- Create: `tests/standalone.nix`
- Modify: `flake.nix` (the `let` block and the end of `outputs`)
- Modify: `tests/default.nix` (the suite list)

**Interfaces:**
- Consumes: `home/shell.nix` (Task 2).
- Produces:
  - The output `homeConfigurations."nwilliams-lucas@ai-agent-host"`.
  - Host files return
    `{ platform = "<system>"; home = <hm module>; os = <system-manager module>?; }`;
    `os` is added in Task 6.
  - `extraSpecialArgs` contains `user`, `version`, `theme`, `inputs`,
    `PROJECT_ROOT` and `hostname`.
  - `home/linux-shell.nix` sets the `switch` alias.

- [ ] **Step 1: Write the failing tests**

Create `tests/standalone.nix`:

```nix
# Standalone home-manager output for Linux agent hosts.
{ flake, lib }:
let
  hmc = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  hm = hmc.config;
in
{
  testStandaloneEvaluates = {
    expr = lib.hasSuffix ".drv" hmc.activationPackage.drvPath;
    expected = true;
  };
  testHomeDirectory = {
    expr = hm.home.homeDirectory;
    expected = "/home/nwilliams-lucas";
  };
  testGenericLinux = {
    expr = hm.targets.genericLinux.enable;
    expected = true;
  };
  # d.shell aliases from home/cli/git/ui.nix reach home.shellAliases.
  testShellAliasesApplied = {
    expr = hm.home.shellAliases.gi or null;
    expected = "lazygit";
  };
  testBuiltinAliases = {
    expr = hm.home.shellAliases."..";
    expected = "cd ..";
  };
  testShellPrograms = {
    expr = [
      hm.programs.zsh.enable
      hm.programs.direnv.enable
      hm.programs.direnv.nix-direnv.enable
      hm.programs.mise.enableZshIntegration
    ];
    expected = [
      true
      true
      true
      true
    ];
  };
  # The two HM-managed tree .envrc files are trusted; nothing broader.
  testDirenvWhitelist = {
    expr = hm.programs.direnv.config.whitelist.exact;
    expected = [
      "/home/nwilliams-lucas/projects/personal/.envrc"
      "/home/nwilliams-lucas/projects/work/.envrc"
    ];
  };
  # ~/.zshenv used to source ~/.cargo/env; HM now owns .zshenv.
  testCargoOnPath = {
    expr = builtins.elem "/home/nwilliams-lucas/.cargo/bin" hm.home.sessionPath;
    expected = true;
  };
  testStarshipVariable = {
    expr = hm.home.sessionVariables.STARSHIP_LOG;
    expected = "error";
  };
}
```

Add `./standalone.nix` to the `suites` list in `tests/default.nix`:

```nix
  suites = [
    ./harness.nix
    ./standalone.nix
  ];
```

```bash
git add tests && just test
```

Expected: FAIL, with an evaluation error that `homeConfigurations` (or
`"nwilliams-lucas@ai-agent-host"`) is missing.

- [ ] **Step 2: Create the host file**

Create `hosts/linux/ai-agent-host.nix`:

```nix
# Headless Ubuntu host for AI agent sessions (Remote Control).
# Discovered by flake.nix: filename = hostname. Outputs:
#   homeConfigurations."nwilliams-lucas@ai-agent-host"  (home)
#   systemConfigs.ai-agent-host                       (os, system-manager)
{
  platform = "x86_64-linux";

  home = { };
}
```

- [ ] **Step 3: Create `home/linux-shell.nix`**

```nix
# Shell wiring for standalone home-manager on Linux. On nix-darwin/NixOS
# these live in the system shell modules (system/darwin/shells.nix,
# system/nixos/shells.nix, system/shells.nix).
{
  config,
  lib,
  user,
  hostname,
  ...
}:
let
  home = config.home.homeDirectory;
  repo = "${home}/projects/personal/nix-darwin-hm";
in
{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
    # Trust exactly the two HM-managed tree hooks (home/default.nix), so they
    # load without `direnv allow` and keep working when their content changes.
    config.whitelist.exact = [
      "${home}/projects/personal/.envrc"
      "${home}/projects/work/.envrc"
    ];
  };

  # home/default.nix disables this because nix-darwin activates mise itself.
  programs.mise.enableZshIntegration = lib.mkForce true;

  # rustup's toolchain (native install); ~/.zshenv no longer sources ~/.cargo/env.
  home.sessionPath = [ "${home}/.cargo/bin" ];

  home.shellAliases.switch = "home-manager switch -b backup --flake ${repo}#${user}@${hostname}";
}
```

- [ ] **Step 4: Create `home/standalone.nix`**

```nix
# Entry module for standalone home-manager hosts (non-NixOS Linux). Supplies
# what nix-darwin/NixOS provide through system/hm.nix and the profiles:
# the d.shell module, the CLI modules (normally injected by
# modules/profiles/base.nix), the shared flake modules, and shell wiring.
{ inputs, ... }:
{
  imports = [
    inputs.nix-index.homeModules.nix-index
    inputs.op-secrets.hmModules.default
    ./shell.nix
    ./linux-shell.nix
    ./cli
    ../modules/rust/rust.nix
    ./default.nix
  ];

  targets.genericLinux.enable = true;
}
```

- [ ] **Step 5: Generate the outputs in `flake.nix`**

In the `let` block of `outputs`, directly after
`PROJECT_ROOT = builtins.toString ./.;`, add:

```nix
      inherit (inputs.nixpkgs.lib)
        filterAttrs
        mapAttrs
        mapAttrs'
        nameValuePair
        recursiveUpdate
        ;

      sharedArgs = {
        user = "nwilliams-lucas";
        theme = "catppuccin";
        version = "26.05";
        inherit PROJECT_ROOT;
      };

      sharedOverlays = [
        inputs.vscode-extensions.overlays.default
        inputs.rust-overlay.overlays.default
      ];

      # Linux hosts managed by standalone home-manager (+ system-manager).
      # hosts/linux/<hostname>.nix returns { platform; home; os?; }.
      linuxHosts = listToAttrs (
        map (f: {
          name = removeSuffix ".nix" (baseNameOf f);
          value = import f;
        }) (builtins.filter (hasSuffix ".nix") (listFilesRecursive ./hosts/linux))
      );

      pkgsFor =
        platform:
        import inputs.nixpkgs-stable {
          system = platform;
          config.allowUnfree = true;
          overlays = sharedOverlays;
        };

      homeConfigurations = mapAttrs' (
        hostname: host:
        nameValuePair "${sharedArgs.user}@${hostname}" (
          inputs.hm.lib.homeManagerConfiguration {
            pkgs = pkgsFor host.platform;
            extraSpecialArgs = sharedArgs // {
              inherit inputs hostname;
            };
            modules = [
              ./home/standalone.nix
              host.home
            ];
          }
        )
      ) linuxHosts;
```

Then change the `sharedOverlays = [ … ];` attribute inside `mkFlake { … }` to
reuse the binding:

```nix
      inherit sharedOverlays;
```

Finally, bind the `mkFlake` result and merge the new output into it. Change
the line `    mkFlake {` (directly after `in`) to:

```nix
    let
      base = mkFlake {
```

and change the closing `    };` of the `mkFlake` call (the last line before
`}` closes `outputs`) to:

```nix
      };
    in
    base
    // {
      inherit homeConfigurations;
    };
```

- [ ] **Step 6: Run the tests**

```bash
git add hosts/linux home/standalone.nix home/linux-shell.nix && nix fmt && just test
```

Expected: `[]`. If evaluation fails because a module needs an argument such as
`hostname` or `PROJECT_ROOT`, check that `extraSpecialArgs` has it. Don't
special-case the module.

- [ ] **Step 7: Prove darwin is unchanged, and the Linux output instantiates**

```bash
just check-darwin && nix eval --raw '.#homeConfigurations."nwilliams-lucas@ai-agent-host".activationPackage.drvPath'
```

Expected: `darwin NWL-MMINI: unchanged vs origin/main`, then a
`/nix/store/…-home-manager-generation.drv` path. Instantiating is enough; this
Mac can't *build* x86_64-linux, and Task 10 builds it on the host.

- [ ] **Step 8: Commit, open the PR and merge**

```bash
git add -A && git commit -m "feat: standalone home-manager output for Linux agent hosts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
git push -u origin feat/standalone-home-manager && gh pr create --base main --title "feat: standalone home-manager output for Linux agent hosts" --body $'## Summary\n- Eval test harness (`just test`) and a darwin config-snapshot gate (`just check-darwin`).\n- Move the home-manager side of `d.shell` into `home/shell.nix`.\n- `homeConfigurations."nwilliams-lucas@ai-agent-host"` via `home/standalone.nix`, discovered from `hosts/linux/`.\n\n## Test plan\n- [x] `just test` prints `[]`\n- [x] `just check-darwin` shows no diff vs `origin/main`\n- [x] Linux activation package instantiates\n\nSpec: `docs/superpowers/specs/2026-09-30-linux-agent-host-design.md`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
```

Then merge and clean up (Global Constraints → Merging):

```bash
gh pr merge --squash --delete-branch; cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree remove .claude/worktrees/standalone-hm && git fetch -q --prune origin && git branch -D feat/standalone-home-manager && git merge -q --ff-only origin/main
```

`gh pr merge --delete-branch` prints an error about `main` being in use by
another worktree. That's expected: the merge and the remote branch deletion
have already happened, which is why the next command continues after `;`.
Confirm the merge with:

```bash
gh pr view feat/standalone-home-manager --json state --jq .state
```

Expected: `MERGED`.
```

---

## PR 2: `fix/linux-home-portability`

```bash
cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree add -b fix/linux-home-portability .claude/worktrees/portability origin/main
```

### Task 4: Gate macOS-only paths in git, ssh and `home/default.nix`

**Files:**
- Modify: `home/cli/git/default.nix` (the `signing = …` block and `settings.gpg`)
- Modify: `home/ssh_config.nix` (the arguments, the three `ProxyCommand`s, the
  `onePassword` block)
- Modify: `home/default.nix` (the `"nix-darwin-reinit"` file entry and the
  `xsession.numlock` line)
- Create: `tests/portability.nix`
- Modify: `tests/default.nix` (the suite list)

**Interfaces:**
- Consumes: `d.apps.onepassword.gui` (bool), added in Task 5. This task reads
  it with `or true`, so it evaluates before Task 5 lands.
- Produces: none for other tasks.

- [ ] **Step 1: Write the failing tests**

Create `tests/portability.nix`:

```nix
# The Linux agent-host output must not reference macOS-only paths or the
# 1Password desktop app.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  blob = builtins.toJSON (import ./lib/hm-snapshot.nix { inherit lib hm; });
in
{
  testNoHomebrewPaths = {
    expr = lib.hasInfix "/opt/homebrew" blob;
    expected = false;
  };
  testNoApplicationsPaths = {
    expr = lib.hasInfix "/Applications/" blob;
    expected = false;
  };
  testNoMacLibraryPaths = {
    expr = lib.hasInfix "Library/Group Containers" blob;
    expected = false;
  };
  testGitSignsWithSshKeygen = {
    expr = lib.hasSuffix "/bin/ssh-keygen" hm.programs.git.settings.gpg.ssh.program;
    expected = true;
  };
  testGitDefaultSigningKey = {
    expr = hm.programs.git.signing.key;
    expected = "~/.ssh/id_ed25519";
  };
  testCloudflaredFromNix = {
    expr = lib.hasInfix "-cloudflared-" hm.programs.ssh.settings.sshNWLNEXUS.ProxyCommand;
    expected = true;
  };
  testNoDarwinReinitScript = {
    expr = hm.home.file."nix-darwin-reinit".enable;
    expected = false;
  };
}
```

Add `./portability.nix` to `suites` in `tests/default.nix`:

```nix
  suites = [
    ./harness.nix
    ./standalone.nix
    ./portability.nix
  ];
```

```bash
git add tests && just test
```

Expected: FAIL. All seven tests above fail. The Linux output currently has
`op-ssh-sign`, `/opt/homebrew` cloudflared, the `Library/Group Containers`
agent block, the 1Password public-key signing key and `nix-darwin-reinit`.

- [ ] **Step 2: Fix git signing in `home/cli/git/default.nix`**

Inside the `let` block, before `in`, add:

```nix
  op = config.d.apps.onepassword;
  opGui = op.enable && (op.gui or true);
```

Replace the existing signing block:

```nix
      #Signing is done via the 1Password app
      signing = lib.mkIf (config.d.apps.onepassword.enable or false) {
        signByDefault = true;
        key = config.d.apps.onepassword.ssh.key;
      };
```

with:

```nix
      # Signing is done via the 1Password app where it runs; headless hosts
      # sign with the on-disk personal key that op-secrets materializes.
      signing = lib.mkMerge [
        (lib.mkIf opGui {
          signByDefault = true;
          key = op.ssh.key;
        })
        (lib.mkIf (!opGui) {
          signByDefault = true;
          key = "~/.ssh/id_ed25519";
        })
      ];
```

Replace:

```nix
      settings.gpg = {
        format = "ssh";
        ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
      };
```

with:

```nix
      settings.gpg = {
        format = "ssh";
        ssh.program =
          if opGui && pkgs.stdenv.isDarwin then
            "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
          else
            "${pkgs.openssh}/bin/ssh-keygen";
      };
```

- [ ] **Step 3: Fix `home/ssh_config.nix`**

Change the arguments line `{ lib, user, ... }:` to:

```nix
{
  config,
  lib,
  pkgs,
  user,
  ...
}:
let
  cloudflared =
    if pkgs.stdenv.isDarwin then
      "/opt/homebrew/bin/cloudflared"
    else
      "${pkgs.cloudflared}/bin/cloudflared";
in
```

Replace each of the three occurrences of
`ProxyCommand = "/opt/homebrew/bin/cloudflared access ssh --hostname %n";` with:

```nix
        ProxyCommand = "${cloudflared} access ssh --hostname %n";
```

Replace the `onePassword = { … };` block with:

```nix
      onePassword = lib.mkIf (pkgs.stdenv.isDarwin && (config.d.apps.onepassword.gui or true)) {
        header = ''Host * exec "test -z $SSH_TTY"'';
        IdentityAgent = ''"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"'';
      };
```

- [ ] **Step 4: Fix `home/default.nix`**

In the `"nix-darwin-reinit" = {` entry, add `enable` as the first attribute:

```nix
      "nix-darwin-reinit" = {
        enable = pkgs.stdenv.isDarwin;
```

Delete the last line of the module, `xsession.numlock.enable = pkgs.stdenv.isLinux;`.
It defaults to `false`, and headless hosts have no X session.

- [ ] **Step 5: Run the tests and the darwin gate**

```bash
nix fmt && just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`. A diff in
`xdg."git/config"` means the darwin `gpg.ssh.program` or signing changed, so
recheck `opGui`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "fix: gate macOS-only git, ssh and helper-script paths

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: Split the 1Password module into secrets (always) and GUI (opt-out)

**Files:**
- Modify: `home/apps/1password.nix` (the options block and the `config = …`
  block)
- Modify: `hosts/linux/ai-agent-host.nix` (`home`)
- Modify: `tests/portability.nix` (add tests)

**Interfaces:**
- Produces:
  - `d.apps.onepassword.gui` (bool, default `true`).
  - `d.apps.onepassword.tokenFiles.{personal,work}` (nullOr str, default
    `null`). Each non-null file becomes that account's
    `serviceAccountTokenCommand = "cat '<file>'"` on every op-secrets secret:
    `dtlrinc.1password.com` → `work`, everything else → `personal`.

- [ ] **Step 1: Add the failing tests**

Append inside the attrset in `tests/portability.nix`:

```nix
  testNoSshAuthSock = {
    expr = hm.home.sessionVariables ? SSH_AUTH_SOCK;
    expected = false;
  };
  testNo1PasswordGuiAutostart = {
    expr = hm.systemd.user.services ? _1password-gui;
    expected = false;
  };
  # op-secrets drops the module-level token whenever a secret sets `account`
  # (all of ours do), so every secret needs its own token command.
  testEverySecretHasToken = {
    expr = lib.all (s: s.serviceAccountTokenCommand != null) (lib.attrValues hm.op-secrets.secrets);
    expected = true;
  };
  testWorkEnvUsesWorkToken = {
    expr = hm.op-secrets.secrets.work-env.serviceAccountTokenCommand;
    expected = "cat /home/nwilliams-lucas/.config/work/1penv";
  };
  testPersonalKeyUsesPersonalToken = {
    expr = hm.op-secrets.secrets.github-personal.serviceAccountTokenCommand;
    expected = "cat /home/nwilliams-lucas/.config/personal/1penv";
  };
```

```bash
just test
```

Expected: FAIL. The five new tests fail, because `gui`/`tokenFiles` don't
exist yet and the GUI pieces are still on.

- [ ] **Step 2: Add the options**

In `home/apps/1password.nix`, inside `options.d.apps.onepassword = { … };` and
after the `ssh = mkOption { … };` block, add:

```nix
    # Desktop-app integration: SSH agent socket, op-ssh-sign commit signing,
    # and GUI autostart. Off on headless hosts.
    gui = mkOption {
      type = types.bool;
      default = true;
    };

    # Raw service-account token files for unattended op-secrets runs. When
    # set, each secret gets a per-secret serviceAccountTokenCommand for its
    # account (op-secrets drops the module-level token for any secret that
    # sets `account`, which all of ours do).
    tokenFiles = {
      personal = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      work = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
```

- [ ] **Step 3: Restructure `config`**

In the `let` block at the top, after `cfg = config.d.apps.onepassword;`, add:

```nix
  tokenCommand =
    account:
    let
      file = if account == "dtlrinc.1password.com" then cfg.tokenFiles.work else cfg.tokenFiles.personal;
    in
    if file == null then null else "cat ${lib.escapeShellArg file}";

  withToken = s: s // { serviceAccountTokenCommand = tokenCommand (s.account or null); };
```

Replace `config = mkIf cfg.enable {` and the GUI-related lines at its start,
down to and including the `d.autostart._1password-gui = { … };` block:

```nix
  config = mkIf cfg.enable {
    # Use for SSH Authentication and Signing
    d.shell.variables = {
      SSH_AUTH_SOCK = cfg.ssh.agent;
    };

    programs.ssh.extraConfig = ''
      IdentityAgent "${cfg.ssh.agent}"
    '';

    # Load 1Password Shell Plugins
    d.shell.sources = [
      "$HOME/.config/op/plugins.sh"
    ];

    d.autostart._1password-gui = {
      exec = "1password --silent";
    };
```

with:

```nix
  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.gui {
      # Use for SSH Authentication and Signing
      d.shell.variables = {
        SSH_AUTH_SOCK = cfg.ssh.agent;
      };

      programs.ssh.extraConfig = ''
        IdentityAgent "${cfg.ssh.agent}"
      '';

      # Load 1Password Shell Plugins
      d.shell.sources = [
        "$HOME/.config/op/plugins.sh"
      ];

      d.autostart._1password-gui = {
        exec = "1password --silent";
      };
    })
    {
```

Wrap the secrets: change `secrets = {` (under `op-secrets = {`) to
`secrets = mapAttrs (_: withToken) {`. Then close the `mkMerge` at the end of
the module: the final `};` that closes `config` becomes:

```nix
    }
  ]);
```

`mapAttrs` and `mkMerge` come from the existing `with lib;`.

- [ ] **Step 4: Configure the host**

Replace `home = { };` in `hosts/linux/ai-agent-host.nix` with:

```nix
  home =
    { config, ... }:
    {
      d.apps.onepassword = {
        gui = false;
        tokenFiles = {
          personal = "${config.home.homeDirectory}/.config/personal/1penv";
          work = "${config.home.homeDirectory}/.config/work/1penv";
        };
      };
    };
```

- [ ] **Step 5: Run the tests and the darwin gate**

```bash
nix fmt && just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`. With
`gui = true` and `tokenFiles = null` on the Macs, every secret gets
`serviceAccountTokenCommand = null`, the existing default, so the op-secrets
activation text must be byte-identical. A diff in
`activation.op-secrets`-style keys means `withToken` produced a non-null value
on darwin.

- [ ] **Step 6: Commit, open the PR and merge**

```bash
git add -A && git commit -m "feat(1password): split GUI integration from op-secrets, add token files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
git push -u origin fix/linux-home-portability && gh pr create --base main --title "fix: make home/ portable to headless Linux" --body $'## Summary\n- Gate macOS-only paths: op-ssh-sign, /opt/homebrew cloudflared, the 1Password agent ssh block, nix-darwin-reinit.\n- `d.apps.onepassword.gui` (default true) splits desktop-app integration from op-secrets.\n- `d.apps.onepassword.tokenFiles` gives every op-secrets secret a per-account token command on headless hosts.\n\n## Test plan\n- [x] `just test` prints `[]` (portability suite)\n- [x] `just check-darwin` shows no diff vs `origin/main`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
```

```bash
gh pr merge --squash --delete-branch; cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree remove .claude/worktrees/portability && git fetch -q --prune origin && git branch -D fix/linux-home-portability && git merge -q --ff-only origin/main
```

---

## PR 3: `feat/system-manager-agent-host`

```bash
cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree add -b feat/system-manager-agent-host .claude/worktrees/system-manager origin/main
```

### Task 6: system-manager input, `system/linux/`, and the `systemConfigs` output

**Files:**
- Modify: `flake.nix` (inputs; the `let` block; the merged outputs)
- Create: `system/linux/default.nix`
- Modify: `hosts/linux/ai-agent-host.nix` (add `os`)
- Create: `tests/system-manager.nix`
- Modify: `tests/default.nix` (the suite list)

**Interfaces:**
- Consumes: `linuxHosts`, `sharedArgs` and `homeConfigurations` from `flake.nix`
  (Task 3).
- Produces:
  - `systemConfigs.<host>`, a derivation whose `.config` is the evaluated
    system-manager config.
  - `packages.<linux platform>.system-manager` and `.home-manager`, the
    CLIs pinned by `flake.lock`, used by Task 7's `scripts/linux-switch.sh`.

- [ ] **Step 1: Write the failing tests**

Create `tests/system-manager.nix`:

```nix
# system-manager OS layer for Linux agent hosts.
{ flake, lib }:
let
  smc = flake.systemConfigs.ai-agent-host;
  sm = smc.config;
in
{
  testSystemConfigEvaluates = {
    expr = lib.hasSuffix ".drv" smc.drvPath;
    expected = true;
  };
  # The Nix installer creates /etc/nix/nix.conf; take it over explicitly.
  testNixConfReplacesInstallerFile = {
    expr = sm.environment.etc."nix/nix.conf".replaceExisting;
    expected = true;
  };
  testTrustedUsers = {
    expr = sm.nix.settings.trusted-users;
    expected = [
      "root"
      "nwilliams-lucas"
    ];
  };
  # Replacing the installer's nix.conf must keep its build-users-group.
  testBuildUsersGroup = {
    expr = sm.nix.settings.build-users-group;
    expected = "nixbld";
  };
  testGithubTokenInclude = {
    expr = lib.hasInfix "!include /etc/nix/github-token.conf" sm.nix.extraOptions;
    expected = true;
  };
  testLinger = {
    expr = builtins.elem "f /var/lib/systemd/linger/nwilliams-lucas 0644 root root -" sm.systemd.tmpfiles.rules;
    expected = true;
  };
  testSshdDropIn = {
    expr = sm.environment.etc."ssh/sshd_config.d/05-nix-hardening.conf".text;
    expected = ''
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      PubkeyAuthentication yes
    '';
  };
  testWeeklyGc = {
    expr = lib.toList sm.systemd.services.nix-gc.startAt;
    expected = [ "Sun *-*-* 03:00:00" ];
  };
  testPinnedCliPackages = {
    expr = builtins.attrNames flake.packages.x86_64-linux;
    expected = [
      "home-manager"
      "system-manager"
    ];
  };
}
```

Add `./system-manager.nix` to `suites` in `tests/default.nix`:

```nix
  suites = [
    ./harness.nix
    ./standalone.nix
    ./portability.nix
    ./system-manager.nix
  ];
```

```bash
git add tests && just test
```

Expected: FAIL, with an evaluation error that `systemConfigs` is missing.

- [ ] **Step 2: Add the input**

In `flake.nix` `inputs`, after the `op-secrets` lines, add:

```nix
    # OS layer for non-NixOS Linux hosts (hosts/linux/*.nix → systemConfigs).
    system-manager.url = "github:numtide/system-manager/v1.1.0";
    system-manager.inputs.nixpkgs.follows = "nixpkgs";
```

```bash
nix flake lock
```

Expected: `flake.lock` gains `system-manager` (plus its own inputs, e.g.
`userborn`). There are no other changes, so check with
`git diff --stat flake.lock`.

- [ ] **Step 3: Create `system/linux/default.nix`**

```nix
# system-manager OS layer shared by every Linux agent host. Deliberately
# small: Ubuntu keeps owning sshd, Tailscale, apt and users; this manages
# Nix's config, GC, user lingering, and an sshd hardening drop-in.
{
  config,
  lib,
  pkgs,
  user,
  ...
}:
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Keep what the Nix installer's own nix.conf provides; we replace it.
    build-users-group = "nixbld";
    max-jobs = "auto";
    trusted-users = [
      "root"
      user
    ];
    download-buffer-size = 134217728; # 128 MiB, same as the Macs
    warn-dirty = false;
  };

  # Private-repo flake inputs read a token from here (optional include;
  # materialized by scripts/bootstrap-agent-host.sh). Same as system/nix.nix.
  nix.extraOptions = ''
    !include /etc/nix/github-token.conf
  '';

  # The Nix installer already wrote /etc/nix/nix.conf; back it up and replace.
  environment.etc."nix/nix.conf".replaceExisting = true;

  # Weekly GC + optimise, matching the Macs (system/nix.nix: Sundays, 30d).
  systemd.services.nix-gc = {
    description = "Nix garbage collection";
    startAt = "Sun *-*-* 03:00:00";
    serviceConfig.Type = "oneshot";
    script = ''
      ${config.nix.package}/bin/nix-collect-garbage --delete-older-than 30d
      ${config.nix.package}/bin/nix store optimise
    '';
  };

  # Lingering = this file existing; lets the user's systemd services (the
  # Remote Control servers) start at boot with nobody logged in.
  systemd.tmpfiles.rules = [
    "f /var/lib/systemd/linger/${user} 0644 root root -"
  ];

  # Mirrors the host's hand-written 10-hardening.conf so new hosts get it too.
  # 05- sorts before 50-cloud-init.conf; sshd keeps the first value it reads.
  # scripts/linux-switch.sh validates (sshd -t) before reloading.
  environment.etc."ssh/sshd_config.d/05-nix-hardening.conf".text = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes
  '';
}
```

- [ ] **Step 4: Add `os` to the host**

In `hosts/linux/ai-agent-host.nix`, after `home = …;`, add:

```nix
  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
  };
```

- [ ] **Step 5: Generate `systemConfigs` and the pinned CLI packages**

In `flake.nix`'s `let` block, after `homeConfigurations = …;`, add:

```nix
      systemConfigs = mapAttrs (
        hostname: host:
        inputs.system-manager.lib.makeSystemConfig {
          extraSpecialArgs = sharedArgs // {
            inherit inputs hostname;
          };
          modules = [
            ./system/linux
            host.os
          ];
        }
      ) (filterAttrs (_: host: host ? os) linuxHosts);

      # CLIs pinned by flake.lock, used by scripts/linux-switch.sh.
      linuxPackages = listToAttrs (
        map (host: {
          name = host.platform;
          value = {
            system-manager = inputs.system-manager.packages.${host.platform}.default;
            home-manager = inputs.hm.packages.${host.platform}.default;
          };
        }) (builtins.attrValues linuxHosts)
      );
```

Replace the merge at the end of `outputs` (from Task 3):

```nix
    base
    // {
      inherit homeConfigurations;
    };
```

with:

```nix
    base
    // {
      inherit homeConfigurations systemConfigs;
      packages = recursiveUpdate (base.packages or { }) linuxPackages;
    };
```

- [ ] **Step 6: Run the tests and the darwin gate**

```bash
git add system/linux && nix fmt && just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`.

If evaluation rejects `startAt`, replace it with an explicit timer and change
`testWeeklyGc` to read `sm.systemd.timers.nix-gc.timerConfig.OnCalendar`:

```nix
  systemd.timers.nix-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "Sun *-*-* 03:00:00";
  };
```

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: system-manager OS layer and systemConfigs for Linux agent hosts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: Switch script, bootstrap script, and the token recipe fix

**Files:**
- Create: `scripts/linux-switch.sh`
- Create: `scripts/bootstrap-agent-host.sh`
- Modify: `justfile`, in `materialize-nix-github-token`: the line
  `sudo chmod 600 /etc/nix/github-token.conf && sudo chown root:wheel /etc/nix/github-token.conf`
- Modify: `home/linux-shell.nix` (the `switch` alias)
- Create: `tests/scripts.nix`
- Modify: `tests/default.nix` (the suite list)

**Interfaces:**
- Consumes: `packages.x86_64-linux.{system-manager,home-manager}` (Task 6).
- Produces: `scripts/linux-switch.sh` (no arguments; host = `hostname -s`) and
  `scripts/bootstrap-agent-host.sh [--dry-run]`.

- [ ] **Step 1: Write the failing tests**

Create `tests/scripts.nix`:

```nix
# Static guarantees about the Linux switch/bootstrap scripts.
{ flake, lib }:
let
  switch = builtins.readFile ../scripts/linux-switch.sh;
  bootstrap = builtins.readFile ../scripts/bootstrap-agent-host.sh;
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
in
{
  # Never reload sshd on a config it rejects (would risk losing ssh access).
  testSwitchValidatesSshd = {
    expr = lib.hasInfix "if sudo sshd -t; then" switch && lib.hasInfix "systemctl reload ssh" switch;
    expected = true;
  };
  # Every mutating bootstrap step is behind a check, so re-runs are no-ops.
  testBootstrapIdempotentGuards = {
    expr = map (s: lib.hasInfix s bootstrap) [
      "if [ -d /nix ]"
      "if [ -s \"$f\" ]"
      "if [ -d \"$HOME/.atuin/bin\" ]"
      "if [ ! -d \"$REPO/.git\" ]"
      "if [ ! -s /etc/nix/github-token.conf ]"
    ];
    expected = [
      true
      true
      true
      true
      true
    ];
  };
  testBootstrapHasDryRun = {
    expr = lib.hasInfix "--dry-run" bootstrap;
    expected = true;
  };
  testSwitchAlias = {
    expr = lib.hasSuffix "/projects/personal/nix-darwin-hm/scripts/linux-switch.sh" hm.home.shellAliases.switch;
    expected = true;
  };
}
```

Add `./scripts.nix` to `suites` in `tests/default.nix`:

```nix
  suites = [
    ./harness.nix
    ./standalone.nix
    ./portability.nix
    ./system-manager.nix
    ./scripts.nix
  ];
```

```bash
git add tests && just test
```

Expected: FAIL, with an evaluation error that `scripts/linux-switch.sh` doesn't
exist.

- [ ] **Step 2: Create `scripts/linux-switch.sh`**

```bash
#!/usr/bin/env bash
#
# linux-switch.sh - apply this Linux host's system-manager and home-manager
# configs from the flake. Host = short hostname (hosts/linux/<host>.nix).
#
# The CLIs come from this flake's packages, so their versions follow flake.lock.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$(hostname -s)"

echo "==> system-manager switch ($HOST)"
nix run "$REPO#system-manager" -- switch --flake "$REPO#$HOST" --sudo

echo "==> sshd: validate drop-ins, then reload"
if sudo sshd -t; then
  sudo systemctl reload ssh
else
  echo "sshd rejected its config; NOT reloading (current daemon keeps running)" >&2
  exit 1
fi

echo "==> home-manager switch ($USER@$HOST)"
nix run "$REPO#home-manager" -- switch -b backup --flake "$REPO#$USER@$HOST"
```

```bash
chmod +x scripts/linux-switch.sh
```

- [ ] **Step 3: Create `scripts/bootstrap-agent-host.sh`**

```bash
#!/usr/bin/env bash
#
# bootstrap-agent-host.sh - one-time, re-runnable setup of a Linux agent host
# managed by this flake (system-manager + standalone home-manager).
#
# Usage: bootstrap-agent-host.sh [--dry-run]
#   --dry-run  print what would change; change nothing
#
# Every step checks before it acts, so a second run is a no-op.
#
set -euo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi

REPO_URL="git@github.com:nwlnexus/nix-darwin-hm.git"
REPO="$HOME/projects/personal/nix-darwin-hm"

say() { printf '\n==> %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then printf '  + %s\n' "$*"; else "$@"; fi
}

say "1/7 Nix (multi-user, nix-installer)"
if [ -d /nix ]; then
  echo "  already installed"
else
  run sh -c 'curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm'
fi
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

say "2/7 1Password service-account tokens"
for acct in personal work; do
  f="$HOME/.config/$acct/1penv"
  if [ -s "$f" ]; then
    echo "  $f present"
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "  + prompt for the $acct token -> $f"
    continue
  fi
  read -rsp "  $acct service-account token: " tok
  echo
  if [ -z "$tok" ]; then
    echo "  empty token; aborting" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")"
  (umask 077 && printf '%s' "$tok" >"$f")
  unset tok
done

say "3/7 Remove native installs that home-manager now provides"
if [ -d "$HOME/.atuin/bin" ]; then run rm -rf "$HOME/.atuin/bin"; fi
if [ -d "$HOME/.config/atuin" ] && [ ! -L "$HOME/.config/atuin" ]; then
  run mv "$HOME/.config/atuin" "$HOME/.config/atuin.pre-nix"
fi
if [ -e /usr/local/bin/starship ]; then run sudo rm -f /usr/local/bin/starship; fi
for b in zoxide mise; do
  if [ -e "$HOME/.local/bin/$b" ]; then run rm -f "$HOME/.local/bin/$b"; fi
done
if dpkg -s direnv >/dev/null 2>&1; then run sudo apt-get remove -y direnv; fi
# bash isn't managed by home-manager here; drop hooks for removed binaries.
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -qE 'atuin|starship|zoxide' "$rc"; then
    run sed -i.pre-nix -E '/atuin|starship|zoxide/d' "$rc"
  fi
done
echo "  kept: ~/.local/share/atuin (history), claude, codex, rustup, apt op"

say "4/7 Flake checkout"
if [ ! -d "$REPO/.git" ]; then
  run git clone "$REPO_URL" "$REPO"
else
  echo "  $REPO present"
fi

say "5/7 Switch (system-manager, then home-manager)"
run "$REPO/scripts/linux-switch.sh"

say "6/7 GitHub token for private flake inputs"
if [ ! -s /etc/nix/github-token.conf ]; then
  env_file="$HOME/projects/personal/.env"
  pat=""
  if [ -f "$env_file" ]; then
    pat="$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' "$env_file" | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
  fi
  if [ -n "$pat" ]; then
    if [ "$DRY" = 1 ]; then
      echo "  + write /etc/nix/github-token.conf (root:root 0600)"
    else
      printf 'access-tokens = github.com=%s\n' "$pat" | sudo tee /etc/nix/github-token.conf >/dev/null
      sudo chmod 600 /etc/nix/github-token.conf
      sudo chown root:root /etc/nix/github-token.conf
    fi
  else
    echo "  no GITHUB_PERSONAL_ACCESS_TOKEN in $env_file yet; re-run after secrets materialize"
  fi
  unset pat
else
  echo "  /etc/nix/github-token.conf present"
fi

say "7/7 Manual follow-ups"
cat <<'EOF'
  For each account (personal, work):
    cd ~/projects/<acct> && claude-<acct>          # accept trust prompt, then /login (paste code)
    codex-<acct> login --device-auth
  Then:
    agents restart && agents status
  If Tailscale shows "Logged out":
    sudo tailscale up
EOF
```

```bash
chmod +x scripts/bootstrap-agent-host.sh
```

- [ ] **Step 4: Point the `switch` alias at the script and fix the recipe**

In `home/linux-shell.nix`, replace the `home.shellAliases.switch = …;` line
with:

```nix
  home.shellAliases.switch = "${repo}/scripts/linux-switch.sh";
```

Also remove `user` and `hostname` from that module's argument list; they're no
longer used.

In `justfile`'s `materialize-nix-github-token`, replace `sudo chown root:wheel`
with `sudo chown "root:$(id -gn root)"`. That gives `wheel` on macOS and `root`
on Linux.

- [ ] **Step 5: Run the tests, shellcheck and the darwin gate**

```bash
git add scripts && nix fmt && just test && nix run nixpkgs#shellcheck -- scripts/linux-switch.sh scripts/bootstrap-agent-host.sh && just check-darwin
```

Expected: `[]`; no shellcheck output; `darwin NWL-MMINI: unchanged vs origin/main`.

- [ ] **Step 6: Commit, open the PR and merge**

```bash
git add -A && git commit -m "feat: linux switch and agent-host bootstrap scripts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
git push -u origin feat/system-manager-agent-host && gh pr create --base main --title "feat: system-manager OS layer for Linux agent hosts" --body $'## Summary\n- `system-manager` input (v1.1.0) and `systemConfigs.<host>` from `hosts/linux/`.\n- `system/linux/`: nix.conf (replaces the installer file), weekly GC, lingering, sshd hardening drop-in.\n- `scripts/linux-switch.sh` (validates sshd before reload) and an idempotent `scripts/bootstrap-agent-host.sh [--dry-run]`.\n- `materialize-nix-github-token` uses the root group portably.\n\n## Test plan\n- [x] `just test` prints `[]`\n- [x] shellcheck clean\n- [x] `just check-darwin` shows no diff vs `origin/main`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
```

```bash
gh pr merge --squash --delete-branch; cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree remove .claude/worktrees/system-manager && git fetch -q --prune origin && git branch -D feat/system-manager-agent-host && git merge -q --ff-only origin/main
```

---

## PR 4: `feat/agent-host-tooling`

```bash
cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree add -b feat/agent-host-tooling .claude/worktrees/agent-tooling origin/main
```

### Task 8: Per-account Claude Code / Codex commands and Remote Control services

**Files:**
- Create: `home/agent-host/default.nix`
- Create: `home/agent-host/services.nix`
- Modify: `home/standalone.nix` (imports)
- Modify: `hosts/linux/ai-agent-host.nix` (`home`)
- Create: `tests/agent-host.nix`
- Modify: `tests/default.nix` (the suite list)

**Interfaces:**
- Consumes: the `hostname` special arg (Task 3), and the
  `home.file."direnv-hook-<acct>"` entries in `home/default.nix`, whose `text`
  type is `lines`, so `mkAfter` appends.
- Produces:
  - `d.agentHost.enable` (bool, default `false`).
  - `d.agentHost.defaultAccount` (str, default `"personal"`).
  - `d.agentHost.accounts.<acct>.root` (str); `<acct>` must be `personal` or
    `work`.
  - Commands `claude-<acct>`, `codex-<acct>` and `agents`.
  - User units `claude-rc-<acct>` and `codex-rc-<acct>`.

- [ ] **Step 1: Write the failing tests**

Create `tests/agent-host.nix`:

```nix
# Per-account agent tooling on Linux agent hosts.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  svc = hm.systemd.user.services;
  h = "/home/nwilliams-lucas";
  pkgNames = map lib.getName hm.home.packages;
in
{
  testRemoteControlUnits = {
    expr = lib.sort lib.lessThan (lib.attrNames (lib.filterAttrs (n: _: lib.hasInfix "-rc-" n) svc));
    expected = [
      "claude-rc-personal"
      "claude-rc-work"
      "codex-rc-personal"
      "codex-rc-work"
    ];
  };
  testClaudeWorkingDirectory = {
    expr = svc.claude-rc-work.Service.WorkingDirectory;
    expected = "${h}/projects/work";
  };
  testClaudeServerMode = {
    expr = lib.hasSuffix "/bin/claude-work remote-control" svc.claude-rc-work.Service.ExecStart;
    expected = true;
  };
  # Foreground form, so systemd supervises it (not `remote-control start`).
  testCodexForeground = {
    expr = lib.hasSuffix "/bin/codex-personal remote-control" svc.codex-rc-personal.Service.ExecStart;
    expected = true;
  };
  testClaudeCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.claude-work/.credentials.json" svc.claude-rc-work.Service.ExecCondition;
    expected = true;
  };
  testCodexCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.codex-personal/auth.json" svc.codex-rc-personal.Service.ExecCondition;
    expected = true;
  };
  testRestartAndBoot = {
    expr = [
      svc.claude-rc-personal.Service.Restart
      svc.claude-rc-personal.Install.WantedBy
    ];
    expected = [
      "always"
      [ "default.target" ]
    ];
  };
  testDefaultAccount = {
    expr = [
      hm.home.sessionVariables.CLAUDE_CONFIG_DIR
      hm.home.sessionVariables.CODEX_HOME
    ];
    expected = [
      "${h}/.claude-personal"
      "${h}/.codex-personal"
    ];
  };
  testWorkDirenv = {
    expr = lib.hasInfix ''export CLAUDE_CONFIG_DIR="${h}/.claude-work"'' hm.home.file."direnv-hook-work".text;
    expected = true;
  };
  testPersonalDirenvNoWork = {
    expr = lib.hasInfix ".claude-work" hm.home.file."direnv-hook-personal".text;
    expected = false;
  };
  testBrainCommandLinked = {
    expr = hm.home.file ? ".claude-work/commands/brain.md";
    expected = true;
  };
  testCommands = {
    expr = map (n: builtins.elem n pkgNames) [
      "claude-personal"
      "claude-work"
      "codex-personal"
      "codex-work"
      "agents"
    ];
    expected = [
      true
      true
      true
      true
      true
    ];
  };
}
```

Add `./agent-host.nix` to `suites` in `tests/default.nix`:

```nix
  suites = [
    ./harness.nix
    ./standalone.nix
    ./portability.nix
    ./system-manager.nix
    ./scripts.nix
    ./agent-host.nix
  ];
```

```bash
git add tests && just test
```

Expected: FAIL. Every agent-host test fails, e.g. `svc.claude-rc-work`
doesn't exist.

- [ ] **Step 2: Create `home/agent-host/default.nix`**

```nix
# Linux agent hosts: one Claude Code / Codex config dir per account, with the
# account picked by the project tree you're in (direnv) or explicitly via
# claude-<acct> / codex-<acct>. Remote Control services: ./services.nix.
{
  config,
  lib,
  ...
}:
let
  cfg = config.d.agentHost;
  home = config.home.homeDirectory;
  claudeDir = acct: "${home}/.claude-${acct}";
  codexDir = acct: "${home}/.codex-${acct}";
  accts = lib.attrNames cfg.accounts;
in
{
  imports = [ ./services.nix ];

  options.d.agentHost = {
    enable = lib.mkEnableOption "per-account Claude Code / Codex and Remote Control services";

    defaultAccount = lib.mkOption {
      type = lib.types.str;
      default = "personal";
      description = "Account used outside every account's project tree.";
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.root = lib.mkOption {
            type = lib.types.str;
            description = "Project tree this account works in (Remote Control working directory).";
          };
        }
      );
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.accounts ? ${cfg.defaultAccount};
        message = "d.agentHost.defaultAccount must name an entry in d.agentHost.accounts";
      }
      {
        # Each account extends that tree's HM-managed direnv hook (home/default.nix).
        assertion = lib.all (a: builtins.elem a [ "personal" "work" ]) accts;
        message = "d.agentHost.accounts: only `personal` and `work` have direnv hooks";
      }
    ];

    home.sessionVariables = {
      CLAUDE_CONFIG_DIR = claudeDir cfg.defaultAccount;
      CODEX_HOME = codexDir cfg.defaultAccount;
    };

    home.file = lib.mkMerge (
      map (acct: {
        ".claude-${acct}/commands/brain.md".source = ../cli/claude/commands/brain.md;
        "direnv-hook-${acct}".text = lib.mkAfter ''
          # Agent account for this tree (home/agent-host).
          export CLAUDE_CONFIG_DIR="${claudeDir acct}"
          export CODEX_HOME="${codexDir acct}"
        '';
      }) accts
    );

    # Per-account gitnexus Claude integration (home/cli/claude does ~/.claude).
    home.activation.agentHostGitnexus = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (acct: ''
        GITNEXUS_BIN="${home}/.local/share/mise/shims/gitnexus"
        if [ -x "$GITNEXUS_BIN" ]; then
          CLAUDE_CONFIG_DIR=${lib.escapeShellArg (claudeDir acct)} "$GITNEXUS_BIN" setup -c claude || true
        fi
      '') accts
    );
  };
}
```

- [ ] **Step 3: Create `home/agent-host/services.nix`**

```nix
# claude-<acct> / codex-<acct> launchers, the always-on Remote Control user
# services built on them, and the `agents` helper. Binaries are the native
# installs in ~/.local/bin (they self-update); Nix only wraps them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost;
  home = config.home.homeDirectory;

  tools = {
    claude = {
      dirVar = "CLAUDE_CONFIG_DIR";
      dir = acct: "${home}/.claude-${acct}";
      creds = ".credentials.json";
      serverArgs = [ "remote-control" ];
    };
    codex = {
      dirVar = "CODEX_HOME";
      dir = acct: "${home}/.codex-${acct}";
      creds = "auth.json";
      # Foreground form; `remote-control start` would daemonize away from systemd.
      serverArgs = [ "remote-control" ];
    };
  };

  # Services get no login shell, so give agent sessions the user's tool PATH.
  agentPath = lib.concatStringsSep ":" [
    "${home}/.local/bin"
    "${home}/.local/share/mise/shims"
    "${home}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "${home}/.cargo/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  # Pin the account, load its tree's op-provisioned .env (tokens), exec the
  # native binary. Used interactively and as the services' ExecStart.
  mkLauncher =
    tool: acct: account:
    let
      t = tools.${tool};
      envFile = "${account.root}/.env";
    in
    pkgs.writeShellScriptBin "${tool}-${acct}" ''
      if [ -f ${lib.escapeShellArg "${home}/.nix-profile/etc/profile.d/hm-session-vars.sh"} ]; then
        . ${lib.escapeShellArg "${home}/.nix-profile/etc/profile.d/hm-session-vars.sh"}
      fi
      export ${t.dirVar}=${lib.escapeShellArg (t.dir acct)}
      if [ -f ${lib.escapeShellArg envFile} ]; then
        set -a
        . ${lib.escapeShellArg envFile}
        set +a
      fi
      if [ -n "''${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
        export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
      fi
      exec ${lib.escapeShellArg "${home}/.local/bin/${tool}"} "$@"
    '';

  pairs = lib.concatMap (
    tool:
    lib.mapAttrsToList (acct: account: {
      inherit tool acct account;
      launcher = mkLauncher tool acct account;
    }) cfg.accounts
  ) (lib.attrNames tools);

  unitName = p: "${p.tool}-rc-${p.acct}";
  units = map unitName pairs;

  agents = pkgs.writeShellApplication {
    name = "agents";
    text = ''
      units=(${lib.escapeShellArgs units})
      case "''${1:-status}" in
        status)
          systemctl --user --no-pager list-units --all "''${units[@]/%/.service}"
          ;;
        restart)
          shift
          if [ $# -gt 0 ]; then
            systemctl --user restart "$@"
          else
            systemctl --user restart "''${units[@]}"
          fi
          ;;
        logs)
          if [ $# -lt 2 ]; then
            echo "usage: agents logs <unit>" >&2
            exit 2
          fi
          journalctl --user -u "$2" -f
          ;;
        *)
          echo "usage: agents [status | restart [unit...] | logs <unit>]" >&2
          exit 2
          ;;
      esac
    '';
  };
in
lib.mkIf cfg.enable {
  home.packages = map (p: p.launcher) pairs ++ [ agents ];

  systemd.user.services = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair (unitName p) {
        Unit.Description = "${p.tool} Remote Control (${p.acct})";
        Service = {
          Type = "simple";
          WorkingDirectory = p.account.root;
          Environment = [ "PATH=${agentPath}" ];
          # Skip (not fail) until this account is logged in.
          ExecCondition = "${pkgs.coreutils}/bin/test -f ${tools.${p.tool}.dir p.acct}/${tools.${p.tool}.creds}";
          ExecStart = "${p.launcher}/bin/${p.tool}-${p.acct} ${lib.escapeShellArgs tools.${p.tool}.serverArgs}";
          Restart = "always";
          RestartSec = 10;
          StandardInput = "null";
        };
        Install.WantedBy = [ "default.target" ];
      }
    ) pairs
  );
}
```

- [ ] **Step 4: Wire it in and enable it on the host**

In `home/standalone.nix` `imports`, add `./agent-host` after `./linux-shell.nix`.

In `hosts/linux/ai-agent-host.nix` `home`, alongside `d.apps.onepassword`, add:

```nix
      d.agentHost = {
        enable = true;
        accounts = {
          personal.root = "${config.home.homeDirectory}/projects/personal";
          work.root = "${config.home.homeDirectory}/projects/work";
        };
      };
```

- [ ] **Step 5: Run the tests and the darwin gate**

```bash
git add home/agent-host && nix fmt && just test && just check-darwin
```

Expected: `[]`, then `darwin NWL-MMINI: unchanged vs origin/main`. Only
`home/standalone.nix` imports `home/agent-host`, so darwin can't change. If it
does, something leaked into a shared module.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: per-account Claude Code/Codex and Remote Control services for agent hosts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: Documentation

**Files:**
- Modify: `AGENTS.md` (`CLAUDE.md`/`GEMINI.md` are symlinks to it; check with
  `ls -l CLAUDE.md`)
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Update `AGENTS.md`**

- **Directory Structure:** under `├── hosts/`, add the line
  `│   └── linux/            # Ubuntu agent hosts (standalone HM + system-manager)`.
  Under `├── system/`, add `│   └── linux/           # system-manager OS layer for hosts/linux`.
  Add a top-level `├── tests/               # Nix evaluation tests (just test)`.
- **Essential Commands:** add `scripts/linux-switch.sh   # Linux agent hosts (alias: switch)`,
  `just test   # Nix evaluation tests` and
  `just check-darwin   # prove darwin config is unchanged vs origin/main`.
- **Current hosts:** add `- **linux (standalone home-manager + system-manager):** ai-agent-host`.
- **New section:** add `### Agent hosts (Linux)` after "Rust build hygiene",
  with these bullets:
  - Hosts are `hosts/linux/<host>.nix` → `{ platform; home; os; }`, with outputs
    `homeConfigurations."nwilliams-lucas@<host>"` and `systemConfigs.<host>`.
  - Bootstrap a new host with
    `scripts/bootstrap-agent-host.sh --dry-run`, then without `--dry-run`. It
    prompts once for `~/.config/{personal,work}/1penv`.
  - Accounts: `personal` → `~/projects/personal`, `work` → `~/projects/work`.
    Plain `claude`/`codex` follow the tree (direnv); `claude-<acct>`/`codex-<acct>`
    are explicit; `personal` is the default elsewhere.
  - Remote Control: user units `claude-rc-<acct>` and `codex-rc-<acct>`, started
    at boot (lingering). Each is skipped until its account logs in. Manage them
    with `agents status|restart|logs <unit>`. Native-installer updates apply on
    `agents restart`.
  - Login per account: `claude-<acct>` inside its tree (trust prompt, `/login`)
    and `codex-<acct> login --device-auth`.
  - Not managed: sshd service, Tailscale, apt (including the `op` beta).

- [ ] **Step 2: Update `README.md` and `ARCHITECTURE.md`**

- **`README.md`:** wherever hosts/platforms are listed, add Linux agent hosts
  (Ubuntu + standalone home-manager + system-manager) and point to the
  `AGENTS.md` section.
- **`ARCHITECTURE.md`:** add a short section covering the new outputs,
  `home/standalone.nix` (what it supplies in place of nix-darwin/NixOS),
  `home/shell.nix`, `d.apps.onepassword.{gui,tokenFiles}`, `d.agentHost.*`,
  `system/linux/` and the `tests/` + `just check-darwin` gate.

```bash
nix run nixpkgs#markdownlint-cli2 -- AGENTS.md README.md ARCHITECTURE.md
```

Expected: no new errors in the edited sections. Fix any you introduced.

- [ ] **Step 3: Commit, open the PR and merge**

```bash
git add -A && git commit -m "docs: Linux agent hosts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

```bash
just test && just check-darwin && git push -u origin feat/agent-host-tooling && gh pr create --base main --title "feat: per-account Claude Code/Codex and Remote Control on agent hosts" --body $'## Summary\n- `d.agentHost`: per-account `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, chosen by project tree (direnv) or `claude-<acct>`/`codex-<acct>`.\n- Always-on `claude-rc-<acct>` / `codex-rc-<acct>` user services (skipped until login), plus an `agents` helper.\n- Docs for Linux agent hosts.\n\n## Test plan\n- [x] `just test` prints `[]` (agent-host suite)\n- [x] `just check-darwin` shows no diff vs `origin/main`\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
```

```bash
gh pr merge --squash --delete-branch; cd /Volumes/REALTEK/projects/personal/nix-darwin-hm && git worktree remove .claude/worktrees/agent-tooling && git fetch -q --prune origin && git branch -D feat/agent-host-tooling && git merge -q --ff-only origin/main
```

---

## On-host rollout

### Task 10: Bootstrap and verify `ai-agent-host`

This runs against the real host over `ssh ai-agent-host.local`. Steps marked
**(user)** need the human partner, because they involve entering secrets or
browser logins. Everything else is run and read by the agent.

- [ ] **Step 1: Dry run**

```bash
ssh ai-agent-host.local 'curl -fsSL https://raw.githubusercontent.com/nwlnexus/nix-darwin-hm/main/scripts/bootstrap-agent-host.sh | bash -s -- --dry-run'
```

Expected:
- `+ sh -c 'curl … nix-installer …'`;
- `+ prompt for the personal token`, `+ prompt for the work token`;
- removals for `~/.atuin/bin`, `/usr/local/bin/starship`, `~/.local/bin/zoxide`,
  `~/.local/bin/mise` and apt `direnv`;
- `sed` lines for `.bashrc`/`.profile`;
- `git clone`;
- `linux-switch.sh`.

- [ ] **Step 2: (user) Run the bootstrap interactively**

Ask the human partner to run this in their own terminal, since it prompts for
both service-account tokens:

```bash
ssh -t ai-agent-host.local 'curl -fsSL https://raw.githubusercontent.com/nwlnexus/nix-darwin-hm/main/scripts/bootstrap-agent-host.sh | bash'
```

- [ ] **Step 3: Verify the switch landed and secrets materialized**

```bash
ssh ai-agent-host.local 'set +e; ls -l ~/.ssh/id_ed25519 ~/.ssh/gitlab-work-gl ~/projects/personal/.env ~/projects/work/.env; ls ~/.zshrc.backup ~/.ssh/config.backup; cat /etc/nix/nix.conf | head -20; loginctl show-user "$USER" -p Linger; sudo sshd -T | grep -iE "^(passwordauthentication|permitrootlogin)"'
```

Expected:
- all four secret files exist, mode `-rw-------`;
- both `.backup` files exist;
- `nix.conf` shows `trusted-users = root nwilliams-lucas`,
  `build-users-group = nixbld` and the `!include` line;
- `Linger=yes`;
- `passwordauthentication no` and `permitrootlogin no`.

If the switch failed on op-secrets, the error names the secret (e.g.
`op-secrets: secret 'work-env': …`). Check that the token file for that
account is correct and the service account can read the vault; that's Review
Focus #2. If `/etc/nix/nix.conf` lost a setting the installer had (compare
with `/etc/nix/nix.conf.*` backups), add it to `system/linux/default.nix` in a
follow-up PR.

- [ ] **Step 4: Verify the bootstrap is idempotent**

```bash
ssh ai-agent-host.local '~/projects/personal/nix-darwin-hm/scripts/bootstrap-agent-host.sh --dry-run'
```

Expected:
- step 1 says `already installed`;
- step 2 says `present` twice;
- step 3 prints only the `kept:` line;
- step 4 says `present`;
- step 5 prints `+ …/linux-switch.sh`;
- step 6 says `present`.

That's Review Focus #5.

- [ ] **Step 5: Verify identities, signing and account selection**

direnv only switches environments at a prompt, so this uses `direnv exec`,
which loads a tree's `.envrc` explicitly:

```bash
ssh ai-agent-host.local 'zsh -lic "set +e; git -C ~/projects/personal config user.email; direnv exec ~/projects/personal printenv CLAUDE_CONFIG_DIR; git -C ~/projects/work config user.email; direnv exec ~/projects/work printenv CLAUDE_CONFIG_DIR CODEX_HOME; cd /tmp && printenv CLAUDE_CONFIG_DIR; ssh -T git@github.com; ssh -T git@github.com-work; command -v starship atuin zoxide direnv mise claude codex op"'
```

`git -C <dir> config user.email` resolves the `gitdir:` includes, because the
nix-darwin-hm checkout sits under `~/projects/personal`. For an empty
`~/projects/work`, create a scratch repo first:
`git init -q ~/projects/work/.scratch`, and use
`git -C ~/projects/work/.scratch`.

Expected:
- in `personal`: `4689066+nwlucas@users.noreply.github.com` and
  `/home/nwilliams-lucas/.claude-personal`;
- in `work`: `59927973+nwilliams-lucas@users.noreply.github.com`,
  `…/.claude-work` and `…/.codex-work`;
- in `/tmp`: `…/.claude-personal`;
- ssh greetings `Hi nwlucas!` and `Hi nwilliams-lucas!`;
- tool paths: starship, atuin, zoxide, direnv and mise under
  `/home/nwilliams-lucas/.nix-profile/bin`; claude and codex under
  `~/.local/bin`; op at `/usr/bin/op`.

This is Review Focus #3.

- [ ] **Step 6: Verify the units wait for login**

```bash
ssh ai-agent-host.local 'agents status; systemctl --user show claude-rc-work -p ActiveState -p Result -p NRestarts; systemctl --user status claude-rc-work --no-pager | tail -3'
```

Expected:
- four units `inactive (dead)`;
- `claude-rc-work` shows `ActiveState=inactive` and `NRestarts=0`;
- its status tail says the unit was skipped because of an unmet condition
  check (`ExecCondition`).

If `NRestarts` keeps climbing, a failed `ExecCondition` is triggering
`Restart=always`. Add `RestartPreventExitStatus=` handling, or change the
units to `Restart=on-failure`, in a follow-up. That's Review Focus #1.

- [ ] **Step 7: (user) Log in to each account**

Ask the human partner to run these in their own terminal, in this order:

```bash
ssh -t ai-agent-host.local 'cd ~/projects/personal && claude-personal'
```

```bash
ssh -t ai-agent-host.local 'cd ~/projects/work && claude-work'
```

```bash
ssh -t ai-agent-host.local 'codex-personal login --device-auth'
```

```bash
ssh -t ai-agent-host.local 'codex-work login --device-auth'
```

- [ ] **Step 8: Confirm the credentials files and start the servers**

```bash
ssh ai-agent-host.local 'ls -la ~/.claude-personal ~/.claude-work ~/.codex-personal ~/.codex-work | grep -E "credentials|auth.json|claude.json"; ls -la ~/.claude.json; agents restart && sleep 5 && agents status'
```

Expected:
- `.credentials.json` exists in both Claude directories and `auth.json` in both
  Codex directories;
- all four units `active (running)`.

If a credentials file has a different name or location, update `creds` in
`home/agent-host/services.nix` and the two condition tests in a follow-up PR.
Note whether `.claude.json` was created *inside* each `~/.claude-<acct>` or
only at `~/.claude.json` (spec item to verify), and record it in `AGENTS.md`.

- [ ] **Step 9: (user) Confirm Remote Control and reboot persistence**

The human partner confirms in claude.ai and the ChatGPT app that each
account shows an `ai-agent-host` Remote Control server. Then:

```bash
ssh ai-agent-host.local 'sudo systemctl reboot' ; sleep 90; ssh ai-agent-host.local 'agents status'
```

Expected: after reboot, all four units are `active (running)` with nobody
logged in.

- [ ] **Step 10: Record the outcome**

If any follow-ups came out of steps 3, 6 or 8, open them as one PR,
`fix/agent-host-followups`, using the same merge flow. Otherwise nothing to
commit.
