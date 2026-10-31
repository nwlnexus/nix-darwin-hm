# data-hub: Mac Studio M1 Max (formerly the MACST-02 entry). Its running nix-darwin generation predates this
# file and was not switched from it; it is a bare profile kept as the tests' plain-Mac fixture until data-hub's
# cluster role is decided (olympus-sdk #661). Review before switching data-hub from this repo.
{ pkgs, user, ... }:
let
  homePrefix = if pkgs.stdenv.isDarwin then "/Users" else "/home";
in
{
  config = {
    d.profiles = {
      base.enable = true;
      dev.enable = true;
      gui-small.enable = true;
      gui-full.enable = false;
      business.enable = false;
      gaming.enable = false;
    };

    ids.gids.nixbld = 30000;
    system.primaryUser = user;

    home-manager = {
      users.${user} = {
        home = { };

        programs = { };
      };
    };
  };
}
