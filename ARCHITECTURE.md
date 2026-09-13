# Architecture Documentation

This document provides detailed architectural information about this nix-darwin + Home Manager flake configuration.

## Overview

This is a pure Nix flake configuration repository that manages NixOS and macOS (nix-darwin) systems with Home Manager. It uses flake-utils-plus for host generation, nix-darwin for macOS system management, and Home Manager for user environment configuration.

## Technology Stack

### Core Technologies

- **Nix Flakes:** Dependency management and reproducible builds
- **nix-darwin:** Declarative macOS system configuration
- **Home Manager:** User-specific dotfiles, packages, and services
- **flake-utils-plus:** Declarative host generation from directory structure
- **NixOS:** Linux distribution (for non-macOS hosts)
- **Languages:** Primarily Nix

### Key Components

- **flake-utils-plus (`mkFlake`):** Enables declarative host generation from directory structure
- **nixpkgs channels:** Supports both stable (26.05) and unstable, with stable as default
- **nix-darwin:** macOS system management integration
- **Home Manager:** User environment configurations
- **impermanence module:** Stateless system support
- **mac-app-util:** Better macOS application integration
- **Overlays:** VSCode extensions and Rust toolchain
- **treefmt-nix:** Code formatting
- **nix-index:** Faster command lookup
- **just:** Task automation

## Detailed Directory Structure

### `/flake.nix`

Main flake configuration defining:

- Input dependencies (nixpkgs, home-manager, nix-darwin, etc.)
- Output configurations for each host
- Host generation logic using flake-utils-plus
- Overlays and system-wide settings

### `/hosts/`

Host-specific configurations organized by platform. Each `.nix` file represents a unique host, with the filename becoming the hostname.

**Platform directories:**

- `darwinM/` → Apple Silicon macOS (aarch64-darwin)
- `darwin/` → Intel macOS (x86_64-darwin)
- `nixos/` → x86_64 Linux (x86_64-linux)
- `nixos-arm/` → ARM64 Linux (aarch64-linux)

**Current hosts:**

- **darwinM:** DTLR-NWLMMINI, MACST-01, MACST-02, NWL-MBM2, NWL-MMINI
- **nixos-arm:** nixos-parallels, rpi-01

### `/system/`

Platform-specific system-level configurations.

**`system/darwin/`** - macOS system configuration:

- `dock.nix` - Dock settings and behavior
- `finder.nix` - Finder preferences
- `fonts.nix` - System fonts
- `brew.nix` - Homebrew packages and casks
- `packages.nix` - macOS-specific system packages
- Additional system preferences

**`system/nixos/`** - NixOS system configuration:

- Boot configuration
- User management
- Hardware settings
- NixOS-specific packages

**`system/default.nix`** - Cross-platform system settings
**`system/packages.nix`** - System-wide packages for all platforms

### `/home/`

Home Manager configurations for user-specific settings.

**`home/cli/`** - Command line tool configurations:

- `git/` - Git aliases, signing, hooks, and identity routing
- `starship.nix` - Starship prompt
- `bat.nix` - Bat (cat alternative)
- `eza.nix` - Eza (ls alternative)
- Additional CLI tools

**`home/apps/`** - Application configurations:

- `iterm2/` - iTerm2 Dynamic Profile that launches tmux in control mode (`-CC`); seeded from `profile.json` (regenerable via `scripts/export-iterm-profile.sh`)
- `1password.nix` - 1Password configuration
- Other GUI applications

**`home/default.nix`** - Base home configuration:

- Session variables
- Session PATH (`~/.local/bin`, `~/go/bin`)
- SSH configuration import
- Autostart programs
- File management (certificates, dotfiles)
- Shell initialization

**`home/ssh_config.nix`** - SSH configuration
**`home/autostart.nix`** - Autostart applications
**`home/eza.nix`** - Eza configuration

### `/modules/`

Shared Nix modules imported across configurations:

- Profile management
- Shell configurations
- Nix daemon settings
- Reusable module definitions

### `/users/`

User configuration schema and data:

- User definitions
- User-specific settings
- Primary user: `nwilliams-lucas`

### `/files/`

Static files used in configuration:

- `files/certs/` - Custom CA certificates (e.g., Cloudflare CA for corporate environments)

## Host Generation Logic

The flake uses the `mkHosts` function with `flake-utils-plus.mkFlake` to automatically generate host configurations. The system:

1. Scans the `/hosts/` directory tree
2. Determines platform from directory suffix:
   - `darwinM/` → aarch64-darwin
   - `darwin/` → x86_64-darwin
   - `nixos-arm/` → aarch64-linux
   - `nixos/` → x86_64-linux
3. Creates a configuration for each `.nix` file found
4. Sets hostname based on filename
5. Imports appropriate system modules based on platform
6. Integrates Home Manager for user configuration

## Configuration Patterns

### Adding a New Host

1. Determine the platform and architecture
2. Create a new `.nix` file in the appropriate `hosts/` subdirectory
3. Filename becomes the hostname
4. Add host-specific configuration:

```nix
# hosts/nixos/my-server.nix
{
  system.stateVersion = "26.05";
  networking.hostName = "my-server";
  # Additional host-specific options...
}
```

### Package Management Strategies

**User-level packages (preferred for most tools):**

- Located in `home/cli/` or `home/apps/`
- Managed per-user via Home Manager
- Better for development tools and user applications
- Supports user-specific configuration

**System-level packages:**

- Located in `system/packages.nix` or platform-specific files
- Available to all users
- Better for system utilities and shared tools

**Homebrew (macOS only):**

- Defined in `system/darwin/brew.nix`
- Used for macOS-specific applications not in nixpkgs
- Supports casks and formulae

### Module Organization

Configurations are highly modular:

1. Base system config imported automatically by platform
2. Host-specific overrides in `/hosts/<platform>/<hostname>.nix`
3. User config in `/home/` imported via Home Manager
4. Shared modules in `/modules/` imported where needed

### Certificate Management

Custom CA certificates are installed from `files/certs/`:

- Cloudflare CA certificate for corporate proxy environments
- Installed to user home directory
- Referenced in `.curlrc` for HTTPS connections

### PATH Management

The user PATH is configured in `home/default.nix`:

- `~/.local/bin` - For custom user scripts
- `~/go/bin` - For Go binaries
- Additional tool-specific paths as needed

## Overlays

The configuration includes overlays for:

- **VSCode extensions:** Custom VSCode extension packages
- **Rust toolchain:** Custom Rust compiler and tool versions
- Applied globally across all configurations

## Version Information

- **NixOS/nix-darwin version:** 26.05
- **Home Manager state version:** 26.05
- **Theme:** Catppuccin
- **Primary user:** nwilliams-lucas

## Development Workflow

### Applying Changes

1. Edit configuration files
2. Format with `nix fmt` or `just fmt`
3. On macOS, test with `just build` or `just check`
4. Apply with `just switch` (macOS) or
   `nixos-rebuild switch --flake .#<hostname>` (NixOS)

### macOS Rebuild Wrapper

`just build`, `just check`, and `just switch` call
`scripts/darwin-rebuild.sh` instead of invoking `darwin-rebuild` directly. The
wrapper exists because desktop hosts keep this repository on an external volume
mounted `noowners`; when root evaluates `sudo darwin-rebuild switch --flake .`,
Nix's libgit2 fetcher may reject the checkout as not owned by the current user.

The wrapper:

1. Defaults the host from `scutil --get LocalHostName` and validates it against
   the flake's `darwinConfigurations`.
2. Uses a normal git-backed flake reference when root can read the checkout.
3. Uses a `path:` flake reference on `noowners` volumes, bypassing libgit2's
   ownership check.
4. Retries with `path:` if the ownership error appears after the first attempt.
5. Supports bootstrap rebuilds with `DARWIN_REBUILD_NIX_CONFIG`, used by
   `just darwin-rebuild-bootstrap` before the root Nix token include is active.

`build` intentionally uses the same flake reference as `switch`; otherwise the
git and path fetchers hash different sources and a build would not warm the
closure used by the later activation.

### Root Nix Credentials

Private flake inputs and the optional R2 binary cache are root-daemon concerns:

- `just materialize-nix-github-token` writes `/etc/nix/github-token.conf` from
  the provisioned personal environment. It enables private GitHub flake inputs,
  such as `github:nwlnexus/mnemosyne`, during root evaluations.
- `just darwin-rebuild-bootstrap` passes that token through `NIX_CONFIG` for the
  first successful switch, before `system/nix.nix` has installed the optional
  `!include`.
- `just materialize-r2-cache-creds` writes `/etc/nix/r2-cache.conf` plus a root
  AWS profile named `nwlnexus-r2` so the Nix daemon can use the R2 substituter.

Both `/etc/nix/*.conf` files are optional includes in `system/nix.nix`; hosts
without them still evaluate, but private fetches or binary-cache substitution may
be unavailable.

### Git Identity Routing

`home/cli/git/default.nix` uses suffix-based `includeIf` conditions so identity
selection works through both symlinked and real checkout paths:

- `gitdir:projects/personal/` loads the personal identity and SSH signing key.
- `gitdir:projects/work/` loads the work identity, GitHub SSH rewrite, and work
  credential username.

Avoid `~/projects/...` conditions. Git matches `gitdir:` against the path used to
enter the repository; IDEs, agents, and `git -C /Volumes/...` can bypass the
symlink and would silently fall back to the default personal identity.

### Updating Dependencies

```bash
nix flake update          # Update all inputs
nix flake lock            # Regenerate lock file
```

### Checking Configuration

```bash
nix flake check           # Validate flake
nix flake show            # Show all outputs
just                      # List available tasks
```

### Formatting

```bash
nix fmt                   # Format all Nix files
just fmt                  # Alternative via just
```

## Best Practices

1. **Modularity:** Keep configurations modular and focused
2. **Reusability:** Use `/modules/` for shared configuration
3. **Documentation:** Comment complex configurations
4. **Testing:** Build before applying to catch errors
5. **Formatting:** Always format with `nix fmt` before committing
6. **Version pinning:** Use flake.lock for reproducibility
7. **User vs System:** Prefer user-level packages when possible

## Troubleshooting

### macOS After System Updates

After macOS system upgrades, the system may overwrite Nix's shell configuration files (`/etc/zshrc` and `/etc/zprofile`), breaking nix-darwin integration. To fix this:

```bash
nix-darwin-reinit [flake-path]
```

This script:

1. Backs up existing shell configuration files to `*.before-nix-darwin`
2. Rebuilds the nix-darwin configuration
3. Restores Nix integration

The script is managed by Home Manager and automatically installed to `~/.local/bin/nix-darwin-reinit`. It defaults to using `~/nix-darwin-hm` as the flake path but accepts a custom path as an argument.

### Build Failures

1. Check syntax with `nix flake check`
2. Verify imports are correct
3. Ensure all required inputs are in flake.nix
4. Check for circular dependencies

### External-Drive macOS Checkouts

If raw `sudo darwin-rebuild switch --flake .` fails with a libgit2 ownership
error on an external-drive checkout, use the supported wrapper:

```bash
just switch
```

To make the raw command use Nix's git fetcher again, register the resolved
checkout path in root's Git config:

```bash
just git-safe-directory
```

The recipe uses `sudo -H` so the setting lands in `/var/root/.gitconfig`, which
is the config root reads during `darwin-rebuild`. Re-run it after moving the
checkout, or remove it with `just git-safe-directory-remove`.

### Private Flake Input Fetches

If root rebuilds cannot fetch private GitHub inputs:

```bash
just materialize-nix-github-token
just darwin-rebuild-bootstrap
```

After that bootstrap switch, subsequent rebuilds can use `just switch` because
`system/nix.nix` includes `/etc/nix/github-token.conf`.

### PATH Issues

If custom scripts aren't found:

1. Verify `~/.local/bin` is in `home.sessionPath` in `home/default.nix`
2. Restart shell or source profile
3. Check script executable permissions

## Additional Resources

- [Nix Flakes Manual](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html)
- [nix-darwin Manual](https://daiderd.com/nix-darwin/manual/index.html)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [flake-utils-plus](https://github.com/gytis-ivaskevicius/flake-utils-plus)
