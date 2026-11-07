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
    system.primaryUser = user;

    home-manager = {
      users.${user} =
        { config, ... }:
        {
          home = { };

          programs = { };

          # op-secrets authenticates with the personal service-account token file
          # instead of the desktop app's CLI integration, so `just switch` does not
          # depend on an unlocked 1Password app. Create the file once:
          #   ~/.config/personal/1penv (0600), the raw OP_SERVICE_ACCOUNT_TOKEN.
          # work-env renders with the dtlr service-account token file
          # (~/.config/work/1penv, 0600); its template no longer reads the Employee
          # vault.
          d.apps.onepassword = {
            tokenFiles = {
              personal = "${config.home.homeDirectory}/.config/personal/1penv";
              work = "${config.home.homeDirectory}/.config/work/1penv";
            };
          };

          # Memory comes from the olympus-memory plugin (olympus-sdk#753): ~/.claude declares
          # the private olympus-private marketplace and enables olympus-memory; its
          # /olympus-memory:setup writes ~/.config/memory (key field `nwl-mstudio-default` in the
          # 1Password item memory-gateway-keys, vault Dev). The nix memory module is off and
          # cleanup removes its hook entries and `memory` MCP entry; key files stay.
          d.claudeHarness.plugins.private.enable = true;
          d.memory = {
            enable = false;
            cleanup = true;
          };
        };
    };
  };
}
