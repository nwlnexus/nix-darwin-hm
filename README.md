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

Use the `just` recipes on macOS. They call `scripts/darwin-rebuild.sh`, which
chooses the current host by default and works whether this repo is on the boot
volume or an external drive mounted `noowners`.

```bash
just switch              # rebuild and activate the current host
just build               # build the current host without activating
just check               # dry-run: build and report what would change
just switch NWL-MBM2     # override the host explicitly
```

Why this wrapper matters: `sudo darwin-rebuild switch --flake .` evaluates as
root. On external-drive hosts, libgit2 can reject the repo because the volume is
mounted without ownership metadata. The wrapper detects that case and uses a
`path:` flake reference, then falls back to the same workaround if the ownership
error appears on a differently mounted host.

If you want bare `sudo darwin-rebuild switch --flake .#<hostname>` to use Nix's
leaner git fetcher on an external-drive host, register the repo in root's Git
config:

```bash
just git-safe-directory
```

Re-run that recipe on each host and after moving the checkout. To undo it for
the current checkout, run `just git-safe-directory-remove`.

Private flake inputs need the root Nix daemon to see the GitHub token. On a new
host or after token rotation, run:

```bash
just materialize-nix-github-token
just darwin-rebuild-bootstrap
```

After a successful switch, `/etc/nix/nix.conf` includes the token file and
normal `just switch` runs do not need the bootstrap recipe.

## Runbooks

* [Mnemosyne backlog catch-up](docs/mnemosyne-catchup.md) — flush a machine's
  parked mnemosyne queue through moneta (`just mnemosyne-catchup`). Use when a
  dev machine was offline/behind and has a large `~/.claude/mnemosyne/queue`.
