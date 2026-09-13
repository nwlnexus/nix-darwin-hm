# NWL's NixOS and macOS Configuration

This repository contains my personal declarative configurations for NixOS and macOS systems, managed using Nix Flakes. It aims to create a reproducible and consistent environment across multiple machines.

## Core Technologies

- [Nix](https://nixos.org/): A powerful package manager and build system.
- [Nix Flakes](https://nixos.wiki/wiki/Flakes): Dependency management for
  reproducible Nix builds.
- [NixOS](https://nixos.org/): A Linux distribution built on top of Nix.
- [nix-darwin](https://github.com/LnL7/nix-darwin): Declarative macOS system
  configuration with Nix.
- [home-manager](https://github.com/nix-community/home-manager): Declarative
  user-specific environments, dotfiles, and packages.

## Structure

The repository is organized as follows:

- `flake.nix`: The entry point for the Nix Flake, defining inputs and outputs.
- `hosts/`: Contains host-specific configurations for each machine.
- `system/`: Contains system-level configurations, separated for `nixos` and
  `darwin`.
- `home/`: Contains user-level configurations managed by `home-manager`.
- `modules/`: Contains reusable Nix modules used across different configurations.
- `users/`: Contains user definitions.

## Usage

To apply the configuration for a specific host, you first need to identify the hostname. You can list all available host configurations by running:

```bash
nix flake show
```

This will show outputs like `darwinConfigurations.NWL-MBM2` or `nixosConfigurations.my-nixos-server`.

### Applying on NixOS

To apply the configuration on a NixOS machine, run the following command, replacing `<hostname>` with the actual hostname of your machine:

```bash
sudo nixos-rebuild switch --flake .#<hostname>
```

### Applying on macOS

Use the checked-in `just` recipes for normal macOS work:

```bash
just build              # Build this host without activating it
just check              # Dry-run the activation plan
just switch             # Build and activate this host
just switch NWL-MBM2    # Override the host explicitly
```

These recipes call `scripts/darwin-rebuild.sh`, which chooses the correct flake
reference for the current machine. On desktops where this repository lives on an
external drive mounted `noowners`, the wrapper uses a `path:` flake reference so
root's `darwin-rebuild` evaluation does not fail libgit2 ownership checks.

Raw `darwin-rebuild` still works on hosts whose checkout is directly readable by
root:

```bash
darwin-rebuild switch --flake .#<hostname>
```

## Runbooks

- **macOS first rebuild with private inputs.** If a host cannot fetch private
  flake inputs such as `github:nwlnexus/mnemosyne`, materialize the root Nix
  token once, then run the bootstrap switch:

  ```bash
  just materialize-nix-github-token
  just darwin-rebuild-bootstrap
  ```

  The materialized file is `/etc/nix/github-token.conf` (`root:wheel`, `0600`).
  After one successful switch, `system/nix.nix` includes it automatically.

- **External-drive checkout and root Git.** `just switch` works without changing
  root's Git config. If you want raw `sudo darwin-rebuild switch --flake .` to
  use the leaner git fetcher instead of the wrapper's `path:` fallback, register
  the resolved checkout path for root on that host:

  ```bash
  just git-safe-directory
  ```

  Re-run this after moving the repository. Undo it with
  `just git-safe-directory-remove`.

- **Git identity routing.** Personal repositories under any
  `projects/personal/` path use the personal SSH signing key; work repositories
  under any `projects/work/` path use the work profile. The patterns intentionally
  match by path suffix, not `~/projects`, so IDEs and agents that traverse the
  real external-volume path still get the right identity.

- [Mnemosyne backlog catch-up](docs/mnemosyne-catchup.md) — flush a machine's
  parked mnemosyne queue through moneta (`just mnemosyne-catchup`). Use when a
  dev machine was offline/behind and has a large `~/.claude/mnemosyne/queue`.
