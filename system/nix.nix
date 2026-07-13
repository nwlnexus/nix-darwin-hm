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

      # Signature key for the nwlnexus R2 binary cache (mnemosyne CI pushes
      # signed closures there — .github/workflows/nix-cache.yml in that repo).
      # Trusting the key is harmless on hosts without the substituter; the
      # substituter itself lives in the materialized conf below because it
      # needs per-host R2 credentials anyway.
      extra-trusted-public-keys = [
        "nix-cache.nwlnexus.io-1:ioP2I0gXFUjZyoPkhHPq2Xqi93zkgIv9VSA+BmGE5I0="
      ];
    };

    # Private-repo flake inputs (e.g. github:nwlnexus/mnemosyne) authenticate via
    # a GitHub access token in /etc/nix/github-token.conf — root-owned 0600,
    # materialized once per host by `just materialize-nix-github-token` (from the
    # op-provisioned PAT in ~/projects/personal/.env). `!include` is the optional
    # form: hosts without the file still evaluate; only private fetches 404.
    #
    # r2-cache.conf (same pattern, `just materialize-r2-cache-creds`) adds the
    # nwlnexus R2 binary cache as an extra substituter; the matching S3
    # credentials land in /var/root/.aws/credentials for the nix daemon.
    extraOptions = ''
      !include /etc/nix/github-token.conf
      !include /etc/nix/r2-cache.conf
    '';

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
