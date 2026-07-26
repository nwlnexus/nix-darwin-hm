{ lib, config, ... }:

{
  config = lib.mkIf config.d.profiles.gui-full.enable {
    d.hm = [
      ../../home/apps/1password.nix
    ];

    homebrew = {
      casks = [
        "1password"
        "angry-ip-scanner"
        "cyberduck"
        "discord"
        "google-chrome"
        "jetbrains-toolbox"
        "microsoft-remote-desktop"
        "raycast"
        "scroll-reverser"
        "parallels"
        "postman"
        "cloudflare-warp"
        "orbstack"
        "proton-mail"
        "protonvpn"
      ];
    };
  };
}
