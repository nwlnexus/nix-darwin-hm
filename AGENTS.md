# AI Assistant Guide

> **Note:** This file is also accessible as `CLAUDE.md` and `GEMINI.md` (symlinks) for compatibility with various AI assistants.

This provides guidance to AI assistants when working with this nix-darwin + Home Manager flake configuration.

## Quick Reference

**Primary user:** `nwilliams-lucas` | **Version:** `26.05` | **Theme:** `catppuccin`

### Essential Commands

```bash
# Apply configuration
just switch                            # macOS: host-portable darwin-rebuild
nixos-rebuild switch --flake .         # NixOS

# macOS maintenance
just build [hostname]                  # Build without activation or sudo
just check [hostname]                  # Dry-run switch; requires sudo
just git-safe-directory                # Allow root git fetcher on noowners drives
nix-darwin-reinit [flake-path]         # Fix nix-darwin after macOS upgrades

# Development
nix flake show                         # List all outputs
nix flake update                       # Update dependencies
nix fmt                                # Format all Nix files
just                                   # List available tasks
```

## Core Technologies

- **Nix:** Package manager and system configuration foundation
- **Nix Flakes:** Dependency management and reproducible builds
- **NixOS:** Linux distribution for declarative system configuration
- **nix-darwin:** Declarative macOS system configuration
- **home-manager:** User-specific dotfiles, packages, and services
- **Languages:** Primarily Nix

### Directory Structure

```bash
├── flake.nix              # Main flake entry point
├── hosts/                 # Host configurations (filename = hostname)
│   ├── darwinM/          # Apple Silicon macOS (aarch64-darwin)
│   ├── darwin/           # Intel macOS (x86_64-darwin)
│   ├── nixos/            # x86_64 Linux
│   └── nixos-arm/        # ARM64 Linux
├── system/               # System-level configs
│   ├── darwin/          # macOS: dock, finder, fonts, brew
│   └── nixos/           # NixOS: boot, users, hardware
├── home/                # Home Manager user configs
│   ├── cli/             # CLI tools: git, starship, bat, etc.
│   └── apps/            # Applications: iterm2, 1password
├── modules/             # Shared Nix modules
│   └── profiles/        # Profile modules (base, dev, gui-full, etc.)
└── users/               # User configuration schema
```

## Common Tasks

### Adding Packages

#### User-Level Packages (Preferred)

User-specific packages should be added to the home-manager configuration, organized by type:

1. **Determine package type:** GUI application (`home/apps/`) or CLI tool (`home/cli/`)
2. **Create configuration file:** For example, `home/cli/htop.nix`
3. **Configure the package:** Use `programs.*` option when available, otherwise use `home.packages`

**Example using `home.packages`:**

```nix
# home/cli/htop.nix
{ pkgs, ... }:
{
  home.packages = [ pkgs.htop ];
}
```

**Example using `programs.*` (preferred when available):**

```nix
# home/cli/fzf.nix
{ pkgs, ... }:
{
  programs.fzf.enable = true;
}
```

4. **Import the new file** in `home/apps/default.nix` or `home/cli/default.nix`:

```nix
# home/cli/default.nix
{
  imports = [
    ./htop.nix
    # ... other imports
  ];
}
```

#### System-Level Packages

For packages available to all users, add to `environment.systemPackages`:

- **All platforms:** `system/packages.nix`
- **macOS only:** `system/darwin/packages.nix`
- **NixOS only:** Relevant file under `system/nixos/`

**Example:**

```nix
# system/packages.nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    htop
    # ... other packages
  ];
}
```

#### Non-official Homebrew taps (tap trust)

Homebrew 6.0+ requires non-official taps to be explicitly trusted. nix-darwin's `homebrew.taps` option cannot emit `trusted: true`, so trusted taps are declared as verbatim Brewfile lines via `homebrew.extraConfig` (which both taps and trusts them), co-located with the profile that uses them (`base.nix`, `dev.nix`, `system/darwin/brew.nix`). Fully-qualified brews/casks like `user/repo/formula` auto-trust that item; declaring the tap as `trusted: true` additionally silences the tap-level "not trusted" warnings.

Interactive `brew trust` is not enough for `darwin-rebuild`: activation runs `brew bundle` via `sudo --user=… --set-home` without `XDG_CONFIG_HOME`, so Homebrew reads `~/.homebrew/trust.json` rather than `~/.config/homebrew/trust.json`. Declare trust in the Brewfile (`extraConfig` / fully-qualified entries) so bundle applies it during activation.

### Adding Hosts

To add a new host configuration:

1. **Create configuration file** in appropriate subdirectory: `hosts/<platform>/<hostname>.nix`
2. **Platform determines architecture:** `darwin/` (Intel macOS), `darwinM/` (Apple Silicon), `nixos/` (x86_64 Linux), `nixos-arm/` (ARM Linux)
3. **Filename becomes hostname:** The base system configuration is auto-imported by `flake.nix`
4. **List available configurations:** Run `nix flake show` to see all outputs

**Example for NixOS:**

```nix
# hosts/nixos/new-server.nix
{
  # Set the state version for NixOS
  system.stateVersion = "26.05";

  # Host-specific configuration
  networking.hostName = "new-server";

  # Add any other host-specific options here
}
```

### Modifying Settings

- **macOS:** `system/darwin/`
- **NixOS:** `system/nixos/`
- **Cross-platform:** `system/default.nix`
- **User environment:** `home/`

### Applying macOS Changes

Prefer the `just` recipes over raw `darwin-rebuild` commands:

```bash
just build             # Build the current host without activating or sudo.
just check             # Build and show what would change; requires sudo.
just switch            # Build and activate the current host; requires sudo.
just switch NWL-MBM2   # Override the detected host when needed.
```

All three recipes go through `scripts/darwin-rebuild.sh`. The wrapper defaults
the host to `scutil --get LocalHostName`, validates that it exists in
`darwinConfigurations`, and keeps `build`/`switch` on the same flake reference so
a build genuinely warms the subsequent switch. `build` stays unprivileged;
`check` and `switch` run `darwin-rebuild` under sudo.

Desktop hosts may keep `~/projects` on an external volume mounted `noowners`.
Root `darwin-rebuild` evaluations then fail when Nix's libgit2 fetcher opens the
repo as `git+file://` because root does not own the checkout. The wrapper detects
that case and uses `path:<repo>#<host>` instead, retrying with the same fallback
if the ownership error appears later. Constraint: `path:` copies the whole
working tree into the Nix store, including gitignored files.

To opt a host back into the leaner git fetcher, run:

```bash
just git-safe-directory
```

This writes the current checkout to root's `safe.directory` list in
`/var/root/.gitconfig`; re-run it per host and after moving the repository. The
recipe uses `sudo -H` intentionally because macOS sudo otherwise preserves the
user's `$HOME`, and root rebuilds do not read the user's git config.

Bootstrap rebuilds that need private GitHub flake inputs use the same wrapper
with root Nix config injected:

```bash
just materialize-nix-github-token
just darwin-rebuild-bootstrap
```

After the first successful switch, `system/nix.nix` includes
`/etc/nix/github-token.conf`, so ordinary `just switch` runs can fetch private
inputs without the bootstrap prefix.

### Git identity & remotes

Git profiles live in `home/cli/git/default.nix`. The work and personal
`includeIf` rules intentionally use suffix-style `gitdir:projects/work/` and
`gitdir:projects/personal/` patterns instead of `~/projects/...`: on desktop
hosts, `~/projects` may be a symlink to `/Volumes/.../projects`, and tools that
open the real path would otherwise miss the intended profile and silently fall
back to the personal identity.

Work GitHub SSH remotes are also rewritten from `git@github.com:` to
`git@github.com-work:` so SSH offers `~/.ssh/gitlab-work-gl`; HTTPS GitHub
credentials are pinned to the work username. If a work push unexpectedly 403s,
check the remote URL, `git config --show-origin --get user.email`, and whether
the checkout path matches the suffix patterns.

This repo's own `betterleaks` pre-commit hook is scoped locally by
`home.activation.nixDarwinHmGitHooks`; it sets `core.hooksPath` only for
`~/projects/personal/nix-darwin-hm` so it does not override Husky or hooks in
other repositories.

### Mnemosyne / Claude Code hooks

Mnemosyne is installed as a mise global (`npm:@nwlnexus/mnemosyne`) in
`home/default.nix`, not as a private Nix flake package. Home Manager activation
in `home/cli/claude/default.nix` explicitly runs `mise install`, strips dead
legacy hook commands from Claude settings, and then calls the `mnemosyne` shim's
`install-hooks`.

Activation scripts do not source an interactive shell profile, so mise globals
must be resolved through their shims and `mise` itself must be on `PATH` for any
nested installer calls. Hooks also cannot rely on a manually sourced `.env`;
op-secrets materializes Moneta and Cloudflare Access credentials under
`~/.config/moneta/` in `home/apps/1password.nix`.

Use [`docs/mnemosyne-catchup.md`](docs/mnemosyne-catchup.md) when a machine has
a parked `~/.claude/mnemosyne/queue`; the old R2/private-flake bootstrap is no
longer part of that workflow.

### Terminal & tmux

- **tmux** is managed by home-manager (`home/cli/tmux.nix`, `programs.tmux`) on all hosts — not Homebrew. It carries the Claude Code integration settings (`allow-passthrough`, `extended-keys` + `xterm*:extkeys`, `focus-events`).
- **iTerm2** is the default terminal on all macOS hosts (`system/darwin/iterm2.nix` installs the cask + sets it as default handler via `duti`).
- The default iTerm2 profile is a **Dynamic Profile** (`home/apps/iterm2/`) that auto-launches `tmux -CC` (control mode). The gateway window is hidden via `AutoHideTmuxClientSession`. The profile is made default by matching `Default Bookmark Guid` (system) to the profile `Guid` (home) — keep these two in sync.
- To refresh the profile template from a host's live settings: `just export-iterm-profile`, then commit `home/apps/iterm2/profile.json`.

### Rust build hygiene

- Rust tooling is templated fleet-wide in `modules/rust/rust.nix`, gated on `d.profiles.dev.rust.enable` (which follows the dev profile). It does **not** install a toolchain — `rustup` from `base.nix` owns that. It only sets global config and helpers.
- All cargo build output goes to a **shared target dir** (`~/.cache/cargo/target`, via `CARGO_TARGET_DIR`) so it isn't duplicated per-repo and there's one place to sweep.
- `sccache` is installed and size-capped (`SCCACHE_CACHE_SIZE=10G`) but is **not** a global `RUSTC_WRAPPER` (that disables incremental compilation). Opt a project in via its `.cargo/config.toml` `[build] rustc-wrapper = "sccache"`.
- A weekly launchd agent (`cargo-sweep`, Sundays 11:00, darwin-only) removes build artifacts unused for 30+ days. Logs: `~/.cache/cargo-sweep/launchd.*.log`.
- `reclaim-disk` (installed to `~/.local/bin`, source `modules/rust/reclaim-disk.sh`) is an on-demand, non-destructive space reclaim for regenerable caches. Run `reclaim-disk --dry-run` first to preview.

### Updating Dependencies

To update all flake inputs to their latest versions:

```bash
nix flake update
```

After updating, apply the configuration to your systems for changes to take effect using the appropriate rebuild command (see Essential Commands above).

## Architecture Details

For in-depth architecture documentation, see [ARCHITECTURE.md](ARCHITECTURE.md).

**Key technical points:**

- Uses `flake-utils-plus.mkFlake` for declarative host generation
- Supports stable (26.05) and unstable nixpkgs channels
- Includes overlays for VSCode extensions and Rust toolchain
- Custom CA certificates from `files/certs/` for corporate environments
- PATH includes `~/.local/bin` for custom scripts (via Home Manager)

**Current hosts:**

- **darwinM:** DTLR-NWLMMINI, MACST-01, MACST-02, NWL-MBM2, NWL-MMINI, NWL-STUDIO, NWL-STUDIO-DTLR
- **nixos-arm:** nixos-parallels, rpi-01

## Notes for AI Assistants

### Workflow Rules

- **Parallel work:** Always perform parallel work as much as possible to maximize efficiency
- **Documentation updates:** Always ensure that documentation in README.md and AGENTS.md is up to date for non-trivial code changes/implementations
- **Git commits:** Always use git commits pre and post non-trivial code changes to track progress and enable rollback
- **Ask questions:** Ask questions for clarification if there are any ambiguities or if unsure about requirements

### Code Quality

- Always format Nix code with `nix fmt` after changes
- Always address markdown lint issues
- Prefer editing existing files over creating new ones
- Test configurations with `nix build .#<configuration>` before applying
- Use relative paths from repo root when referencing files
- Check `just` commands for project-specific tasks

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **nix-darwin-hm** (973 symbols, 1636 relationships, 56 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/nix-darwin-hm/context` | Codebase overview, check index freshness |
| `gitnexus://repo/nix-darwin-hm/clusters` | All functional areas |
| `gitnexus://repo/nix-darwin-hm/processes` | All execution flows |
| `gitnexus://repo/nix-darwin-hm/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
