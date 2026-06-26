{ pkgs, ... }:
{
  nix = {
    enable = true;

    package = pkgs.nixVersions.latest;

    settings = {
      trusted-users = [
        "root"
        "@admin"
      ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      download-buffer-size = 134217728; # 128 MiB — prevents buffer-full warnings on large builds
      warn-dirty = false;
    };

    # Linux builder VM (NixOS aarch64-linux guest via Apple Virtualization).
    # Provides aarch64-linux build capability on this aarch64-darwin host —
    # needed for building Linux Nix derivations (e.g. mvm microVM images).
    linux-builder = {
      enable = true;
      maxJobs = 4;
    };

    optimise.automatic = true;

    gc = {
      automatic = true;
      interval = {
        Weekday = 0;
      }; # Sundays
      options = "--delete-older-than 30d";
    };
  };
}
