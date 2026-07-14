# NWL's NixOS and macOS Configuration

This repository contains my personal declarative configurations for NixOS and macOS systems, managed using Nix Flakes. It aims to create a reproducible and consistent environment across multiple machines.

## Core Technologies

* [Nix](https://nixos.org/): A powerful package manager and build system.
* [Nix Flakes](https://nixos.wiki/wiki/Flakes): A new, improved way to manage Nix expressions and dependencies.
* [NixOS](https://nixos.org/): A Linux distribution built on top of the Nix package manager.
* [nix-darwin](https://github.com/LnL7/nix-darwin): To manage macOS configurations with Nix.
* [home-manager](https://github.com/nix-community/home-manager): To manage user-specific environments (dotfiles, packages) declaratively.

## Structure

The repository is organized as follows:

* `flake.nix`: The entry point for the Nix Flake, defining inputs and outputs.
* `hosts/`: Contains host-specific configurations for each machine.
* `system/`: Contains system-level configurations, separated for `nixos` and `darwin`.
* `home/`: Contains user-level configurations managed by `home-manager`.
* `modules/`: Contains reusable Nix modules used across different configurations.
* `users/`: Contains user definitions.

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

To apply the configuration on a macOS machine using `nix-darwin`, run:

```bash
darwin-rebuild switch --flake .#<hostname>
```

Or if you don't have `darwin-rebuild` in your path:

```bash
nix run nix-darwin -- switch --flake .#<hostname>
```

## Runbooks

- [Mnemosyne backlog catch-up](docs/mnemosyne-catchup.md) — flush a machine's
  parked mnemosyne queue through moneta (`just mnemosyne-catchup`). Use when a
  dev machine was offline/behind and has a large `~/.claude/mnemosyne/queue`.
