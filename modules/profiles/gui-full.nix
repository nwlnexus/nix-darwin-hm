{ lib, config, ... }:

{
  config = lib.mkIf config.d.profiles.gui-full.enable {
    d.hm = [
      ../../home/apps/1password.nix
    ];

    homebrew = {
      casks = [
        # Beta channel of the 1Password desktop app. Conflicts with the stable
        # `1password` cask; see the preActivation migration below.
        "1password@beta"
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

    # `1password@beta` conflicts with the stable `1password` cask (both ship
    # 1Password.app). `brew bundle` installs before it cleans up, so remove the
    # stable cask first. Uninstall (not zap) keeps vaults and settings in
    # ~/Library/Group Containers. Idempotent: a no-op once it's gone. Delete
    # once every host has switched.
    system.activationScripts.preActivation.text = ''
      if [ -x /opt/homebrew/bin/brew ] \
        && sudo --user=${config.system.primaryUser} --set-home \
          /opt/homebrew/bin/brew list --cask 1password >/dev/null 2>&1; then
        echo >&2 "removing stable 1password cask (replaced by 1password@beta)..."
        sudo --user=${config.system.primaryUser} --set-home \
          /opt/homebrew/bin/brew uninstall --cask 1password
      fi
    '';
  };
}
