{
  pkgs,
  lib,
  config,
  ...
}:

{
  config = lib.mkIf config.d.profiles.base.enable {
    environment.systemPackages =
      with pkgs;
      [
        # from system/packages.nix
        act
        cmake
        coreutils
        curl
        fzf
        gnumake
        httpie
        killall
        lsof
        fastfetch
        ripgrep
        unzip
        bat
        vim
        zoxide
        jq
        yq-go
        btop
        cheat
        just
        rustup
        direnv
        starship
        p7zip.out
        libisoburn
        sops
        age
        ssh-to-age
        tree
        nixfmt
        gnupg
      ]
      ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);

    # Add home-manager configurations for CLI tools to the list of hm modules
    d.hm = [
      ../../home/cli
    ];

    homebrew = {
      brews = [
        "cloudflared"
        "openssl@3"
        "nwlnexus/olympus/atlas"
        # tmux is now managed by home-manager (home/cli/tmux.nix)
        "gh"
        # mise now provided by home-manager (programs.mise) — see home/default.nix
        "pkgconf"
        # olympus-sdk VM test harness (vms/harness/vm.sh): qemu-system-* + qemu-img
        # + edk2 UEFI firmware. Declared here so `cleanup = "uninstall"` keeps it.
        "qemu"
      ]
      ++ lib.optional (config.d.profiles.base.tailscale == "formula") "tailscale";
      casks = [
        # Beta channel of the 1Password CLI (`op`). Conflicts with the stable
        # `1password-cli` cask; see the preActivation migration below.
        "1password-cli@beta"
      ]
      ++ lib.optional (config.d.profiles.base.tailscale == "app") "tailscale-app";

      # Homebrew 6.0 (June 2026) requires non-official taps to be explicitly
      # trusted. nix-darwin's `taps` option can't emit `trusted: true`, so we
      # declare trusted taps here as verbatim Brewfile lines (this both taps
      # and trusts them). See https://docs.brew.sh/Tap-Trust
      #
      # Note: `cloudflared` now lives in homebrew-core, so the old
      # `cloudflare/cloudflare` tap is no longer needed and has been dropped.
      extraConfig = ''
        tap "nwlnexus/olympus", trusted: true
      '';
    };

    # `1password-cli@beta` conflicts with the stable `1password-cli` cask (both
    # ship `op`). `brew bundle` installs before it cleans up, so the beta install
    # would fail while the stable cask is still present. Remove the stable cask
    # first. Idempotent: a no-op once it's gone. Delete once every host has
    # switched.
    system.activationScripts.preActivation.text = ''
      if [ -x /opt/homebrew/bin/brew ] \
        && sudo --user=${config.system.primaryUser} --set-home \
          /opt/homebrew/bin/brew list --cask 1password-cli >/dev/null 2>&1; then
        echo >&2 "removing stable 1password-cli cask (replaced by 1password-cli@beta)..."
        sudo --user=${config.system.primaryUser} --set-home \
          /opt/homebrew/bin/brew uninstall --cask 1password-cli
      fi
    '';
  };
}
