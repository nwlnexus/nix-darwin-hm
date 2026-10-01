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
