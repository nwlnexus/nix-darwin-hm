# Snapshot of one darwin host: its home-manager config plus the system-level
# package and Homebrew lists. Compared across git refs by `just check-darwin`.
{
  flake,
  host,
  user ? "nwilliams-lucas",
}:
let
  lib = flake.inputs.nixpkgs.lib;
  cfg = flake.darwinConfigurations.${host}.config;
in
{
  home = import ./hm-snapshot.nix {
    inherit lib;
    hm = cfg.home-manager.users.${user};
  };
  systemPackages = lib.sort lib.lessThan (map lib.getName cfg.environment.systemPackages);
  homebrew = {
    brews = map (b: b.name) cfg.homebrew.brews;
    casks = map (c: c.name) cfg.homebrew.casks;
    inherit (cfg.homebrew) extraConfig;
  };
}
