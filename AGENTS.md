# AI Assistant Guide

> **Note:** This file is also accessible as `CLAUDE.md` and `GEMINI.md` (symlinks) for compatibility with various AI assistants.

This provides guidance to AI assistants when working with this nix-darwin + Home Manager flake configuration.

## Quick Reference

**Primary user:** `nwilliams-lucas` | **Version:** `26.05` | **Theme:** `catppuccin`

### Essential Commands

```bash
# Apply configuration
just switch                            # macOS (host-portable wrapper)
just build                             # macOS build only, no activation
just check                             # macOS dry-run/change preview
nixos-rebuild switch --flake .         # NixOS

# macOS maintenance
nix-darwin-reinit [flake-path]         # Fix nix-darwin after macOS upgrades
just git-safe-directory                # Let root Git open external-drive checkouts
just materialize-nix-github-token      # Give root Nix access to private flake inputs

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

### macOS rebuilds and bootstrap pitfalls

- Prefer `just switch`, `just build`, and `just check` over bare
  `darwin-rebuild` on macOS. They call `scripts/darwin-rebuild.sh`, default to
  the current host, and accept an explicit host such as `just switch NWL-MBM2`.
- The wrapper exists for desktop hosts where `~/projects` resolves to an
  external volume mounted `noowners`. Root evaluation of `--flake .` goes through
  libgit2, which can reject those checkouts as "not owned by current user".
  `scripts/darwin-rebuild.sh` detects that case and uses a `path:` flake ref,
  falling back to `path:` if the ownership error appears unexpectedly.
- `build` and `switch` deliberately use the same flake reference so a build
  warms the cache for the following switch. Do not mix bare `darwin-rebuild
  build --flake .` with `just switch` when investigating closure differences.
- `just git-safe-directory` registers the current checkout in root's
  `/var/root/.gitconfig` so bare root `darwin-rebuild` can use the leaner Git
  fetcher. Re-run it per host and after moving the checkout; use
  `just git-safe-directory-remove` to undo the current checkout.
- New hosts need `just materialize-nix-github-token` before root can fetch
  private flake inputs such as `github:nwlnexus/mnemosyne`. The first rebuild
  before `/etc/nix/nix.conf` includes that file should use
  `just darwin-rebuild-bootstrap`; later runs can use `just switch`.

### Git identity routing

- Personal and work Git profiles are selected in `home/cli/git/default.nix`.
  The `gitdir:` include patterns intentionally use bare suffixes like
  `gitdir:projects/work/` and `gitdir:projects/personal/`, not `~/projects/...`.
- Git expands those bare patterns across any prefix, so they match both the
  symlinked path and the resolved external-volume path. Restoring a `~/` prefix
  breaks IDEs, `git -C /Volumes/...`, and agent harnesses by silently falling
  back to the personal identity for work repos.
- Work GitHub SSH remotes are rewritten through the `github.com-work` host alias
  from `home/ssh_config.nix`; HTTPS remotes pin the GitHub credential helper to
  the work username.

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

This project is indexed by GitNexus as **nix-darwin-hm**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

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

<!-- gitnexus:end -->
