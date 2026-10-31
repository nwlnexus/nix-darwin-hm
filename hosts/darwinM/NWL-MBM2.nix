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
      gui-full.enable = true;
      business.enable = true;
      gaming.enable = false;
    };

    ids.gids.nixbld = 350;
    system.primaryUser = "nwilliams-lucas";

    home-manager = {
      users.${user} =
        { config, ... }:
        {
          home = { };

          programs = { };

          # op-secrets authenticates with the personal service-account token file
          # (~/.config/personal/1penv, 0600) instead of the desktop app's CLI
          # integration, as on nwl-mstudio; work-env uses the dtlr token file
          # (~/.config/work/1penv).
          d.apps.onepassword = {
            tokenFiles = {
              personal = "${config.home.homeDirectory}/.config/personal/1penv";
              work = "${config.home.homeDirectory}/.config/work/1penv";
            };
          };

          # Memory gateway client (olympus-sdk #444/#559): key field `NWL-MBM2-default`
          # in the 1Password item memory-gateway-keys (vault Dev). Tailnet mode.
          d.memory = {
            enable = true;
            host = "NWL-MBM2";
          };
        };
    };
  };
}
