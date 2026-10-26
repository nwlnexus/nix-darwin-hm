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
          # work-env reads the dtlr Employee vault, which no service account can
          # read; it is excluded here as on ai-agent-host until that item moves to
          # a shared vault (then add tokenFiles.work and drop the exclusion).
          # moneta-token reads vault CI, which the personal service account cannot
          # see, and only served the retired mnemosyne writer.
          d.apps.onepassword = {
            tokenFiles.personal = "${config.home.homeDirectory}/.config/personal/1penv";
            excludeSecrets = [
              "work-env"
              "moneta-token"
            ];
          };
        };
    };
  };
}
