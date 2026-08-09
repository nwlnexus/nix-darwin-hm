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

Use the host-portable `just` recipes on macOS:

```bash
just build             # Build the current host without activating or sudo.
just check             # Build and show what would change; requires sudo.
just switch            # Build and activate the current host; requires sudo.
just switch <hostname> # Override the detected host.
```

The recipes call `scripts/darwin-rebuild.sh`, which defaults the host to
`scutil --get LocalHostName` and verifies it exists under `darwinConfigurations`
before starting a rebuild. The wrapper is also safe on desktop hosts where this
repo lives under an external drive mounted `noowners`: it uses a `path:` flake
reference when root's libgit2 cannot open the checkout, then retries with that
same fallback if the ownership error appears on a host that was not detected up
front.

If the repo is on an external drive and you want to use the leaner git fetcher
instead of the `path:` fallback, register this checkout for root's git:

```bash
just git-safe-directory
```

Re-run it per host and after moving the repository. The recipe intentionally uses
`sudo -H` so the entry lands in `/var/root/.gitconfig`, which is the config read
by root `darwin-rebuild` evaluations.

For the first rebuild on a host that needs private GitHub flake inputs, materialize
the token and use the bootstrap recipe:

```bash
just materialize-nix-github-token
just darwin-rebuild-bootstrap
```

After that switch succeeds, `/etc/nix/nix.conf` includes the token file and
ordinary `just switch` runs do not need the bootstrap prefix.

## Runbooks

* [Mnemosyne backlog catch-up](docs/mnemosyne-catchup.md) — flush a machine's
  parked mnemosyne queue through moneta (`just mnemosyne-catchup`). Use when a
  dev machine was offline/behind and has a large `~/.claude/mnemosyne/queue`.
