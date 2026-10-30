# AI Assistant Guide

> **Note:** This file is also accessible as `CLAUDE.md` and `GEMINI.md` (symlinks) for compatibility with various AI assistants.

This provides guidance to AI assistants when working with this nix-darwin + Home Manager flake configuration.

## Quick Reference

**Primary user:** `nwilliams-lucas` | **Version:** `26.05` | **Theme:** `catppuccin`

### Essential Commands

```bash
# Apply configuration
darwin-rebuild switch --flake .        # macOS
nixos-rebuild switch --flake .         # NixOS
scripts/linux-switch.sh                # Linux agent hosts (alias: switch)

# macOS maintenance
nix-darwin-reinit [flake-path]         # Fix nix-darwin after macOS upgrades

# Development
nix flake show                         # List all outputs
nix flake update                       # Update dependencies
nix fmt                                # Format all Nix files
just                                   # List available tasks
just test                              # Nix evaluation tests (tests/)
just check-darwin                      # Prove darwin config unchanged vs origin/main
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
│   ├── nixos-arm/        # ARM64 Linux
│   └── linux/            # Ubuntu agent hosts (standalone HM + system-manager)
├── system/               # System-level configs
│   ├── darwin/          # macOS: dock, finder, fonts, brew
│   ├── nixos/           # NixOS: boot, users, hardware
│   └── linux/           # system-manager OS layer for hosts/linux
├── home/                # Home Manager user configs
│   ├── cli/             # CLI tools: git, starship, bat, etc.
│   └── apps/            # Applications: iterm2, 1password
├── modules/             # Shared Nix modules
│   └── profiles/        # Profile modules (base, dev, gui-full, etc.)
├── tests/               # Nix evaluation tests (just test)
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

Finally, **import the new file** in `home/apps/default.nix` or `home/cli/default.nix`:

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

#### 1Password (beta)

All macOS hosts install `op` from the `1password-cli@beta` cask (`modules/profiles/base.nix`). `gui-full` hosts also install the desktop app from `1password@beta` (`modules/profiles/gui-full.nix`). Each beta cask conflicts with its stable cask (`1password-cli`, `1password`), so a `preActivation` step uninstalls the stable cask before `brew bundle` runs. Uninstall keeps vaults and settings. Once the stable cask is gone, the step does nothing. The beta app keeps the same `1Password.app` path and agent socket.

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

### Adding/migrating a Mac

Host files are lowercase or uppercase as the machine is named; the flake picks the config by hostname, so the name must match the file name exactly. Example: moving to a new Mac with Migration Assistant (`hosts/darwinM/nwl-mstudio.nix`, copied from `NWL-MMINI.nix`):

1. **Hostname first.** Before the first rebuild: `sudo scutil --set ComputerName <host>; sudo scutil --set LocalHostName <host>; sudo scutil --set HostName <host>`. Migration Assistant keeps or prompts for names.
2. **Install Nix fresh** (`install.sh`). `/nix` is a separate APFS volume and is not migrated, so the migrated home has dotfile symlinks into a store that does not exist yet.
3. **`just build` as your user** (the private `olympus-sdk` input is read over ssh), then `just switch`.
4. **Tailscale:** the migrated state clones the old node identity. Run `tailscale logout`, log in again so it registers as a new node, and rename the node. Never run both machines with the same identity.
5. **Memory client** (owner step, `d.memory.host` must equal the flake host name; the 1Password field is `<host>-<account>`). In the cluster:
   `sudo k3s kubectl -n memory exec deploy/memory-gateway -- node dist/admin/cli.js client create --id claude-code@<host>:default --kind gateway_key --scopes read,write,forget`
   (client ids are lowercase), then store the printed key once as field `<host>-default` in item `memory-gateway-keys`, vault `Dev`. The switch replaces the migrated `~/.config/memory/gateway-key`. Revoke the old machine's client with `client revoke <id>`.
6. **Other state:** sign in to 1Password; `~/.config/personal/1penv` comes across with the migration.

### Modifying Settings

- **macOS:** `system/darwin/`
- **NixOS:** `system/nixos/`
- **Cross-platform:** `system/default.nix`
- **User environment:** `home/`

### Terminal & tmux

- **tmux** is managed by home-manager (`home/cli/tmux.nix`, `programs.tmux`) on all hosts — not Homebrew. It carries the Claude Code integration settings (`allow-passthrough`, `extended-keys` + `xterm*:extkeys`, `focus-events`).
- **iTerm2** is the default terminal on all macOS hosts (`system/darwin/iterm2.nix` installs the cask + sets it as default handler via `duti`).
- The default iTerm2 profile is a **Dynamic Profile** (`home/apps/iterm2/`) that auto-launches `tmux -CC` (control mode). The gateway window is hidden via `AutoHideTmuxClientSession`. The profile is made default by matching `Default Bookmark Guid` (system) to the profile `Guid` (home) — keep these two in sync.
- To refresh the profile template from a host's live settings: `just export-iterm-profile`, then commit `home/apps/iterm2/profile.json`.

### mvmctl (microVMs)

- `modules/mvmctl/package.nix` packages the pinned prebuilt mvmctl release (aarch64-darwin, x86_64-linux, aarch64-linux). `modules/mvmctl/home.nix` installs it via home-manager. macOS hosts get it through `system/darwin/mvmctl.nix`, and Linux agent hosts through `home/standalone.nix`.
- macOS 26+ uses the built-in HVF backend and needs **no Homebrew deps**, so don't re-add the libkrun stack (libkrun, libkrunfw, gvproxy, virglrenderer-krun, libepoxy). The package ad-hoc re-signs `mvmctl` and `mvm-hvf-supervisor` with the entitlement profiles in the release's `assets/`, the same way upstream's `install.sh` does.
- Linux uses Firecracker (mvmctl downloads it) and needs `/dev/kvm`. `system/linux/kvm.nix` grants the user an rw ACL on it with a udev rule, which needs no group change or re-login. The rule must sort after `73-seat-late.rules`, because `uaccess` rewrites the device's ACLs.
- On Linux, mvmctl runs through a wrapper that puts a `systemd-run` shim on its PATH. The shim adds `--expand-environment=no`, because systemd-run >= 254 expands mvm's `$$` and every Firecracker boot fails. Drop the shim once upstream fixes this.
- `mvmctl doctor` checks the host. Run `mvmctl bootstrap` once per host to prewarm its caches.
- To bump: update `version` and every `hash` (sha256 from the release's `checksums-sha256.txt`, converted with `nix hash convert --hash-algo sha256 --to sri`).
- A manual `curl … | sh` install in `~/.local/bin` would shadow the Nix one on PATH. A home-manager activation step (`mvmctlManualInstallCleanup`) removes it; once it is gone, the step does nothing.

### Rust build hygiene

- Rust tooling is templated fleet-wide in `modules/rust/rust.nix`, gated on `d.profiles.dev.rust.enable` (which follows the dev profile). It does **not** install a toolchain — `rustup` from `base.nix` owns that. It only sets global config and helpers.
- All cargo build output goes to a **shared target dir** (`~/.cache/cargo/target`, via `CARGO_TARGET_DIR`) so it isn't duplicated per-repo and there's one place to sweep.
- `sccache` is installed and size-capped (`SCCACHE_CACHE_SIZE=10G`) but is **not** a global `RUSTC_WRAPPER` (that disables incremental compilation). Opt a project in via its `.cargo/config.toml` `[build] rustc-wrapper = "sccache"`.
- A weekly launchd agent (`cargo-sweep`, Sundays 11:00, darwin-only) removes build artifacts unused for 30+ days. Logs: `~/.cache/cargo-sweep/launchd.*.log`.
- `reclaim-disk` (installed to `~/.local/bin`, source `modules/rust/reclaim-disk.sh`) is an on-demand, non-destructive space reclaim for regenerable caches. Run `reclaim-disk --dry-run` first to preview.

### Agent hosts (Linux and macOS)

- `d.agentHost` (`home/agent-host/`) runs on both platforms. Linux agent hosts get it from `home/standalone.nix`; every Mac imports it through `system/darwin/agent-host.nix` (`d.hm`) but it stays off until the host sets `home-manager.users.<user>.d.agentHost.enable = true` (default `false`, so the existing Macs evaluate unchanged; `just check-darwin`). Everything below applies to both unless it names a platform.
- Per-host feature toggles: `d.agentHost.accounts.<acct>.remoteControl.claude` / `.codex` (default `true`: the Remote Control service for that account and tool), `d.agentHost.secondBrain.enable` (default `true`; a work-only host sets `false`, which drops the clone, the pull job, `second-brain-sync` and the `SECOND_BRAIN_PATH` override) and `d.agentHost.gitnexus.enable` (default `true`: the `agentHostGitnexus` mirror). The `claude-<acct>`/`codex-<acct>` launchers are installed for every account either way.
- macOS: Remote Control runs as launchd user agents `claude-rc-<acct>` and `codex-rc-<acct>` (`launchd.agents`, label `org.nix-community.home.<unit>`, `RunAtLoad`, `ThrottleInterval` 10 s). These agents have not yet run on real Mac hardware (olympus-sdk #691). `KeepAlive` is `true`. launchd has no `ExecCondition`, so the agent's `/bin/sh -c` program waits until the account is logged in, checking once a minute and logging the wait once, before it starts the server. Claude counts as logged in when `~/.claude-<acct>/.credentials.json` exists or `~/.claude-<acct>/.claude.json` has `oauthAccount`, because on macOS Claude Code keeps the token in the Keychain. Codex uses `codex-<acct> login status`. Codex drives its managed daemon as on Linux: the agent stops any old daemon, starts it, then waits and stops it again when launchd stops the agent. PATH is `~/.local/bin`, mise shims, the per-user Nix profile, `/run/current-system/sw/bin`, the system dirs and Homebrew last; the launchers source the per-user profile's `hm-session-vars.sh` (so `NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem` and the rest apply). Logs: `~/Library/Logs/agent-host/<unit>.log` (the `agentHostLogDir` activation creates the dir before `setupLaunchAgents`). `agents status` prints each unit's `launchctl print gui/$UID/<label>` state, pid and last exit code; `agents restart [unit...]` runs `launchctl kickstart -k`; `agents logs <unit>` tails the log file. Second-brain, when on, is the launchd agent `second-brain-pull` (`StartInterval` 3600, `RunAtLoad`, log `~/Library/Logs/agent-host/second-brain-pull.log`). Tests: `tests/agent-host-darwin.nix` (evaluates `MACST-01` with the layer on).
- Linux: headless Ubuntu hosts live in `hosts/linux/<host>.nix`, which returns `{ platform; home; os; }`. Each produces `homeConfigurations."nwilliams-lucas@<host>"` (standalone home-manager, entry `home/standalone.nix`) and `systemConfigs.<host>` (system-manager, `system/linux/`).
- Bootstrap a new host with `scripts/bootstrap-agent-host.sh --dry-run`, then without `--dry-run`. It prompts once for the 1Password service-account tokens (`~/.config/{personal,work}/1penv`), which every op-secrets secret uses via `d.apps.onepassword.tokenFiles`.
- Accounts (`hosts/linux/ai-agent-host.nix`): `personal` → `~/projects/personal`, `work` → `~/projects/work` (`d.agentHost.accounts`). Plain `claude`/`codex` follow the tree you are in (a zsh prompt hook sets `CLAUDE_CONFIG_DIR`/`CODEX_HOME` from `$PWD`, after direnv, so repos with their own `.envrc` keep the right account); `claude-<acct>`/`codex-<acct>` pick one explicitly; `personal` is the default elsewhere.
- Remote Control (Linux): user units `claude-rc-<acct>` and `codex-rc-<acct>` start at boot (lingering) and are skipped until that account is logged in. Manage them with `agents status | restart [unit] | logs <unit>`. Native-installer updates take effect on `agents restart`.
- Log in once per account: run `claude-<acct>` inside its tree (trust prompt, then `/login`), and `codex-<acct> login --device-auth`.
- Second-brain wiki (olympus-sdk #562, `home/agent-host/second-brain.nix`): the private `nwlnexus/second-brain` repo is cloned over SSH (the host's own GitHub key, nothing stored in Nix) to `d.agentHost.secondBrain.path` = `~/.local/share/second-brain`, outside both account trees, by the `secondBrainClone` activation (only when missing; fail-soft; never touches an existing non-empty dir or local edits). `SECOND_BRAIN_PATH` points there for every session (hm-session-vars, sourced by shells and the `claude-<acct>` launchers); hosts without it (every Mac not running the agent-host layer, or with `secondBrain.enable = false`) keep the Obsidian vault default from `home/cli/claude` (`mkDefault`). On Linux the user timer `second-brain-pull.timer` (hourly, persistent, 5 min jitter) runs `second-brain-sync pull` = `git pull --ff-only`: it logs to the journal (`journalctl --user -u second-brain-pull`), fails visibly when diverged/dirty/offline, and never resets or force-pulls. `/brain` is the command `~/.claude-<acct>/commands/brain.md` for both accounts. Tests: evaluation in `tests/agent-host.nix`, `just test-second-brain-sync`.
- Claude skills: reusable ones live in [`nwlnexus/agent-skills`](https://github.com/nwlnexus/agent-skills) (flake input `agent-skills`, source only). Every `skills/<name>` there is symlinked into `~/.claude/skills/` (`home/cli/claude`) and each `~/.claude-<acct>/skills/` (`home/agent-host`). Add a skill there, then `nix flake update agent-skills` + switch. The same input carries the session harness (`home/cli/claude/harness.nix`, olympus-sdk #560): every `agents/<name>.md` is linked into `<dir>/agents/`, and `fragments/session-contract.md` (frontmatter dropped) is kept between `<!-- agent-skills:session-contract:start/end -->` markers at the end of `<dir>/CLAUDE.md` by the `claudeSessionContract` activation (`home/cli/claude/contract.sh`; text outside the markers is never touched; `just test-claude-contract`). `<dir>` is each `~/.claude-<acct>` on agent hosts, Linux or macOS (`~/.claude` stays unwired there), and `~/.claude` on the other Macs; `d.claudeHarness.enable = false` turns it off. The gitnexus-written `gitnexus-*` skills are mirrored into the account dirs by the `agentHostGitnexus` activation (`gitnexus setup` ignores `CLAUDE_CONFIG_DIR`); `NODE_EXTRA_CA_CERTS` is set to the system bundle because `npx`-launched MCP servers otherwise fail TLS.
- Hooks (olympus-sdk #561, #576): each hook in the `hooks` list of `home/cli/claude/harness.nix` (`{ name; event; }`, files under `hooks/` in agent-skills) is linked to `<dir>/hooks/<name>` and merged into `<dir>/settings.json` as an `<event>` entry (matcher `*`) by the `claudeHooks` activation (`home/cli/claude/hook-wire.sh`, same jq-merge approach as `home/cli/memory/wire.sh`: it matches its own entry by the script's file name, replaces it in place, touches nothing else and never replaces the file; `just test-claude-hook-wire`). Because the match is on the file name, an entry running a hand-installed copy of the same script elsewhere is replaced rather than doubled. `progress-stale.sh` is a `Stop` hook: it prints `progress file <path> last updated <n> minutes ago` when the work tree has a `docs/progress/*.md` older than 20 minutes, and never blocks. `permission-denied-log.sh` is a `PermissionDenied` hook: it appends each auto-mode denial to `~/.local/state/agent/denials.jsonl` and never changes what the session sees.
- Permission rules and auto mode (olympus-sdk #576, layers 1 and 2): the `claudeSettings` activation (`home/cli/claude/settings-wire.sh`, `just test-claude-settings-wire`) adds every rule of `d.claudeHarness.settings.allow` (default: the `gh pr`/`gh issue`/`gh run`/`git push -u origin` rules) that is missing from `.permissions.allow` (union: it never removes or reorders a rule) and replaces `.autoMode` as a whole. The autoMode source is `config/claude/auto-mode.json` in the private `olympus-sdk` input (`d.claudeHarness.settings.autoModeFile`), turned into `{ allow; environment; }` by `home/cli/claude/auto-mode.nix`, which appends a `**Host containment**` entry for `d.claudeHarness.settings.autoModeHost` (or the file's `default`); `hosts/linux/ai-agent-host.nix` sets the host. When the pinned `olympus-sdk` has no such file, `autoModeFile` is `null` and `.autoMode` is left untouched. `d.claudeHarness.settings.enable = false` stops this wiring (what it already wrote stays). Like the hooks, it runs after `agentHostDirs`, is idempotent and fail-soft, and never replaces the file. The autoMode content is private: keep it in olympus-sdk, never in this public repo (tests use `tests/fixtures/claude-auto-mode.json`, made up).
- `agent-session <account> <repo> <issue> [extra claude args]` (`home/cli/claude/agent-session.sh`, installed to `~/.local/bin` on the agent hosts and the Macs) starts `tmux new -d -s <account>-<repo>-<issue> -c ~/projects/<account>/<repo> "CLAUDE_CONFIG_DIR=~/.claude-<account> claude --remote-control <name> --name <name>"`, so the session appears on claude.ai under that name and in `tmux ls`; on the Macs (one `~/.claude`) `CLAUDE_CONFIG_DIR` is left out. If the tmux session exists it attaches instead. `agent-session list` lists sessions and `agent-session attach <name>` attaches (`just test-claude-agent-session`). This is the interactive tmux substrate of the harness spec (H17b); the Remote Control server units above stay for unattended goals.
- Not managed: the sshd service, Tailscale, and apt packages (including the `op` beta). system-manager only adds `/etc/ssh/sshd_config.d/05-nix-hardening.conf` (`scripts/linux-switch.sh` validates it with `sshd -t` before reloading) and the `/dev/kvm` udev ACL rule.
- Linuxbrew (`d.linuxbrew`, `home/linuxbrew.nix`) carries only formulae nixpkgs lacks or lags badly on. home-manager writes `~/.Brewfile` (non-official taps as `trusted: true`) and each switch runs `brew bundle install --no-upgrade`: install-only, never upgrades or removes, and a failure only warns. Brew's `bin` is appended last to PATH (shells and Remote Control services) so it never shadows Nix/mise.
- `d.apps.onepassword.gui = false` turns off the 1Password desktop integration (agent socket, op-ssh-sign, autostart); git then signs with `~/.ssh/id_ed25519`.

### Memory gateway client (Claude Code)

`home/cli/memory` wires every Claude account to the on-prem memory gateway (olympus-sdk epic #444, design `docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md` sections 5.6, 7 and 11 in `nwlnexus/olympus-sdk`). It is **off by default** (`d.memory.enable = false`): merging it changes nothing on any host.

- **What it does** (per Claude config dir): merges the `SessionStart`/`Stop`/`PreCompact`/`SessionEnd` hook entries (plus a `PreToolUse` guard on `mcp__memory__.*` when a route table is set) into `<dir>/settings.json` and a `memory` MCP server (`type: http`, `headersHelper`) into the account's `.claude.json` (`~/.claude.json` for `~/.claude`), and writes the gateway key (plus the Cloudflare Access service token in `public` mode or with `fallback`) to `~/.config/memory/*` (0600) from 1Password. It never touches the Desktop app's chat config (`claude_desktop_config.json`); the Desktop app's local Code sessions read the same `~/.claude/settings.json` and `~/.claude.json`, so they get the same hooks, MCP entry and routing.
- **Personal/work boundary** (olympus-sdk #675): `d.memory.routes` (default `~/projects/personal` -> `gateway`, `~/projects/work` -> `none`; per account `accounts.<n>.routes`) is written to the store and passed to every hook, the `headersHelper` and the guard as `MEMORY_ROUTES_FILE`. The session's working directory picks the backend (longest root; no match, a crossing symlink or worktree = `none`): capture is routed per hook call (a `cd` across roots is followed), recall by the start directory, the MCP key by the session's directory (no key outside the gateway's roots, so the server fails to connect), and each memory tool call by its cwd (the guard). `routes = null` restores the route-less behaviour. A work-side memory system becomes a backend of its own once the hooks implement it.
- **Claude owns those files.** `home/cli/memory/wire.sh` merges with `jq` and touches only entries whose command runs `memory-capture`/`memory-session-start`/`memory-mcp-guard` and an `mcpServers.memory` whose `headersHelper` runs `memory-mcp-headers` (a foreign `memory` server is left alone and reported). It is idempotent, updates in place, writes nothing when nothing changed, and records the files it wired in `~/.local/state/memory-nix/wired.json` so that dropping an account or disabling the module removes its entries again (`d.memory.cleanup = true` with `enable = false` for one switch). Test it with `bash tests/memory-wire.sh`.
- **Secrets are fail-soft.** `home/cli/memory/fetch-secrets.sh` reads the items with `op read` and warns when one is missing (existing files are kept); it does not use `op-secrets`, whose activation is fail-fast and would abort every other secret on a missing item. It honours `d.apps.onepassword.tokenFiles.personal` and `excludeSecrets` (`memory-key-<account>`, `memory-access-client-id`, `memory-access-client-secret`). Test: `bash tests/memory-fetch-secrets.sh`.
- **The package** is `packages/memory-hooks` of the private `nwlnexus/olympus-sdk`, a `flake = false` input read over **ssh** (`git+ssh://git@github.com/nwlnexus/olympus-sdk`; the `github:` fetcher and its PAT cannot see that repo). Only `bin/` and `share/memory/` are installed, unchanged; the source revision is in `$out/nix-support/source-rev`. After the hooks change upstream: `nix flake update olympus-sdk`, review the diff, switch. A root `darwin-rebuild` cannot use your ssh key: run `just build` first as your user so the locked input is already in the store.
- **Enable on a host** (after the 1Password items exist, see the PR/README of the memory gateway): `d.memory.enable = true;` in the host file (`hosts/linux/ai-agent-host.nix` enables it for `personal` only, `work.enable = false` since #675; defining any `accounts.*` replaces the module's default account set, so list every account you want, e.g. `accounts = { default.enable = false; personal = { }; work = { }; }`); nix-darwin hosts also set `d.memory.host = "<flake host name>"` (the 1Password fields are `<host>-<account>`). `d.memory.mode = "public"` for machines off the tailnet, `d.memory.fallback = true` for the hook fallback on tailnet hosts.
- **1Password** (vault `Dev`, account `my.1password.com`): `memory-gateway-keys` with one field per host account (`<host>-default`, `<host>-personal`, ...; mint with `memory-admin client create`), and for `public`/`fallback` `memory-access-tokens` with `<host>-id` and `<host>-secret` (Cloudflare Access service token, policy `service-auth`).
- **Evaluation tests** are in `tests/memory.nix` (`just test`); the enabled variants are evaluated through `extendModules`, nothing is activated.

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

- **darwinM:** DTLR-NWLMMINI, MACST-01, MACST-02, NWL-MBM2, NWL-MMINI, nwl-mstudio
- **nixos-arm:** nixos-parallels, rpi-01
- **linux (standalone home-manager + system-manager):** ai-agent-host

## Notes for AI Assistants

### Workflow Rules

- **Parallel work:** Always perform parallel work as much as possible to maximize efficiency
- **Documentation updates:** Always ensure that documentation in README.md and AGENTS.md is up to date for non-trivial code changes/implementations
- **Git commits:** Always use git commits pre and post non-trivial code changes to track progress and enable rollback
- **CI:** `.github/workflows/validate.yml` (job `validate`, the required check) runs `nix fmt -- --fail-on-change`, `just test` and the `just test-*` bash recipes on GitHub-hosted runners. The repo is public, so CI cannot fetch the private `olympus-sdk` input: it re-points the input at `tests/fixtures/olympus-sdk-stub` in the runner's checkout only (never commit that `flake.lock` change). Keep the stub in step with whatever the tests read from `olympus-sdk`
- **Merging:** label the PR `automerge` (`gh pr edit <n> --add-label automerge`) and `.github/workflows/automerge.yml` squash-merges it once the base branch's required checks pass (GitHub App credentials: olympus-sdk#576)
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
