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
        neofetch
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
        atuin
        p7zip.out
        libisoburn
        sops
        age
        ssh-to-age
        tree
        nixfmt-rfc-style
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
        "gemini-cli"
        "nwlnexus/olympus/atlas"
        # tmux is now managed by home-manager (home/cli/tmux.nix)
        "gh"
        "mise"
        "pkgconf"
      ];
      casks = [
        "1password-cli"
        "tailscale-app"
      ];

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
  };
}
