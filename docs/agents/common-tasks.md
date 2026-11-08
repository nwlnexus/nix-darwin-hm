# Common tasks

> Read on demand; moved out of the always-loaded `AGENTS.md` / `CLAUDE.md` (olympus-sdk#840). Adding packages and hosts, Mac migration, settings, terminal, microVMs, Rust builds, dependency updates.

## Adding Packages

### User-Level Packages (Preferred)

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

### System-Level Packages

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

### Non-official Homebrew taps (tap trust)

Homebrew 6.0+ requires non-official taps to be explicitly trusted. nix-darwin's `homebrew.taps` option cannot emit `trusted: true`, so trusted taps are declared as verbatim Brewfile lines via `homebrew.extraConfig` (which both taps and trusts them), co-located with the profile that uses them (`base.nix`, `dev.nix`, `system/darwin/brew.nix`). Fully-qualified brews/casks like `user/repo/formula` auto-trust that item; declaring the tap as `trusted: true` additionally silences the tap-level "not trusted" warnings.

Interactive `brew trust` is not enough for `darwin-rebuild`: activation runs `brew bundle` via `sudo --user=… --set-home` without `XDG_CONFIG_HOME`, so Homebrew reads `~/.homebrew/trust.json` rather than `~/.config/homebrew/trust.json`. Declare trust in the Brewfile (`extraConfig` / fully-qualified entries) so bundle applies it during activation.

### 1Password (beta)

All macOS hosts install `op` from the `1password-cli@beta` cask (`modules/profiles/base.nix`). `gui-full` hosts also install the desktop app from `1password@beta` (`modules/profiles/gui-full.nix`). Each beta cask conflicts with its stable cask (`1password-cli`, `1password`), so a `preActivation` step uninstalls the stable cask before `brew bundle` runs. Uninstall keeps vaults and settings. Once the stable cask is gone, the step does nothing. The beta app keeps the same `1Password.app` path and agent socket.

## Adding Hosts

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

## Adding/migrating a Mac

Host files are lowercase or uppercase as the machine is named; the flake picks the config by hostname, so the name must match the file name exactly. Example: moving to a new Mac with Migration Assistant (`hosts/darwinM/nwl-mstudio.nix`, copied from the retired `NWL-MMINI.nix`):

1. **Hostname first.** Before the first rebuild: `sudo scutil --set ComputerName <host>; sudo scutil --set LocalHostName <host>; sudo scutil --set HostName <host>`. Migration Assistant keeps or prompts for names.
2. **Install Nix fresh and do the first switch** (`./install.sh`: installs Homebrew and *upstream* Nix with `--prefer-upstream-nix`, since nix-darwin refuses to activate on Determinate Nix, then runs the first `sudo nix run nix-darwin/<release>#darwin-rebuild -- switch --flake .#<host>`; if Determinate Nix is already present it stops and tells you to run `sudo /nix/nix-installer uninstall`). `/nix` is a separate APFS volume and is not migrated, so the migrated home has dotfile symlinks into a store that does not exist yet.
3. **`just switch` as your user** for later changes: it runs `just build` (unprivileged, so the private `olympus-sdk` input is read over your ssh key) before the root switch. If the first switch in `install.sh` cannot read private inputs yet, finish ssh setup and rerun `just switch`.
4. **Tailscale:** the migrated state clones the old node identity. Run `tailscale logout`, log in again so it registers as a new node, and rename the node. Never run both machines with the same identity.
5. **Memory client** (owner step; the `olympus-memory` plugin's `/olympus-memory:setup` writes `~/.config/memory`; the 1Password field is `<host>-<account>`). In the cluster:
   `sudo k3s kubectl -n memory exec deploy/memory-gateway -- node dist/admin/cli.js client create --id claude-code@<host>:default --kind gateway_key --scopes read,write,forget`
   (client ids are lowercase), then store the printed key once as field `<host>-default` in item `memory-gateway-keys`, vault `Dev`. The switch replaces the migrated `~/.config/memory/gateway-key`. Revoke the old machine's client with `client revoke <id>`.
6. **Other state:** sign in to 1Password; `~/.config/personal/1penv` comes across with the migration.

## Modifying Settings

- **macOS:** `system/darwin/`
- **NixOS:** `system/nixos/`
- **Cross-platform:** `system/default.nix`
- **User environment:** `home/`

## Terminal & tmux

- **tmux** is managed by home-manager (`home/cli/tmux.nix`, `programs.tmux`) on all hosts — not Homebrew. It carries the Claude Code integration settings (`allow-passthrough`, `extended-keys` + `xterm*:extkeys`, `focus-events`).
- **iTerm2** is the default terminal on all macOS hosts (`system/darwin/iterm2.nix` installs the cask + sets it as default handler via `duti`).
- The default iTerm2 profile is a **Dynamic Profile** (`home/apps/iterm2/`) that auto-launches `tmux -CC` (control mode). The gateway window is hidden via `AutoHideTmuxClientSession`. The profile is made default by matching `Default Bookmark Guid` (system) to the profile `Guid` (home) — keep these two in sync.
- To refresh the profile template from a host's live settings: `just export-iterm-profile`, then commit `home/apps/iterm2/profile.json`.

## mvmctl (microVMs)

- `modules/mvmctl/package.nix` packages the pinned prebuilt mvmctl release (aarch64-darwin, x86_64-linux, aarch64-linux). `modules/mvmctl/home.nix` installs it via home-manager. macOS hosts get it through `system/darwin/mvmctl.nix`, and Linux agent hosts through `home/standalone.nix`.
- macOS 26+ uses the built-in HVF backend and needs **no Homebrew deps**, so don't re-add the libkrun stack (libkrun, libkrunfw, gvproxy, virglrenderer-krun, libepoxy). The package ad-hoc re-signs `mvmctl` and `mvm-hvf-supervisor` with the entitlement profiles in the release's `assets/`, the same way upstream's `install.sh` does.
- Linux uses Firecracker (mvmctl downloads it) and needs `/dev/kvm`. `system/linux/kvm.nix` grants the user an rw ACL on it with a udev rule, which needs no group change or re-login. The rule must sort after `73-seat-late.rules`, because `uaccess` rewrites the device's ACLs.
- On Linux, mvmctl runs through a wrapper that puts a `systemd-run` shim on its PATH. The shim adds `--expand-environment=no`, because systemd-run >= 254 expands mvm's `$$` and every Firecracker boot fails. Drop the shim once upstream fixes this.
- `mvmctl doctor` checks the host. Run `mvmctl bootstrap` once per host to prewarm its caches.
- To bump: update `version` and every `hash` (sha256 from the release's `checksums-sha256.txt`, converted with `nix hash convert --hash-algo sha256 --to sri`).
- A manual `curl … | sh` install in `~/.local/bin` would shadow the Nix one on PATH. A home-manager activation step (`mvmctlManualInstallCleanup`) removes it; once it is gone, the step does nothing.

## Rust build hygiene

- Rust tooling is templated fleet-wide in `modules/rust/rust.nix`, gated on `d.profiles.dev.rust.enable` (which follows the dev profile). It does **not** install a toolchain — `rustup` from `base.nix` owns that. It only sets global config and helpers.
- All cargo build output goes to a **shared target dir** (`~/projects/.cache/cargo/target`, set only by `[build] target-dir` in `~/.cargo/config.toml`, never `CARGO_TARGET_DIR`, which would override it) so it isn't duplicated per-repo and there's one place to sweep.
- `sccache` is installed and size-capped (`SCCACHE_CACHE_SIZE=10G`) but is **not** a global `RUSTC_WRAPPER` (that disables incremental compilation). Opt a project in via its `.cargo/config.toml` `[build] rustc-wrapper = "sccache"`.
- A weekly launchd agent (`cargo-sweep`, Sundays 11:00, darwin-only) removes build artifacts unused for 30+ days. Logs: `~/.cache/cargo-sweep/launchd.*.log`.
- `reclaim-disk` (installed to `~/.local/bin`, source `modules/rust/reclaim-disk.sh`) is an on-demand, non-destructive space reclaim for regenerable caches. Run `reclaim-disk --dry-run` first to preview.

## Updating Dependencies

To update all flake inputs to their latest versions:

```bash
nix flake update
```

After updating, apply the configuration to your systems for changes to take effect using the appropriate rebuild command (see Essential Commands above).
