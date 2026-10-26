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
          # vault. moneta-token reads vault CI, which the personal service account
          # cannot see, and only served the retired mnemosyne writer.
          d.apps.onepassword = {
            tokenFiles = {
              personal = "${config.home.homeDirectory}/.config/personal/1penv";
              work = "${config.home.homeDirectory}/.config/work/1penv";
            };
            excludeSecrets = [ "moneta-token" ];
          };

          # Memory gateway client (olympus-sdk #444/#559): ~/.claude gets the capture
          # hooks and the `memory` MCP server; key field `NWL-MMINI-default` in the
          # 1Password item memory-gateway-keys (vault Dev). Tailnet mode, no fallback
          # until the Cloudflare Access application exists.
          d.memory = {
            enable = true;
            host = "NWL-MMINI";
          };
        };
    };
  };
}
