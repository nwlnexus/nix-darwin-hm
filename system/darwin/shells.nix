{
  pkgs,
  lib,
  user,
  ...
}:
let
  homePrefix = if pkgs.stdenv.isDarwin then "/Users" else "/home";
in
{
  # Change the default shell to zsh
  home.activation = {
    setDefaultShell = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [[ "$SHELL" != *zsh ]]
      then
        $DRY_RUN_CMD /usr/bin/chsh -s /run/current-system/sw/bin/zsh
      fi
    '';
  };

  programs = {
    zsh = {
      enable = true;
      autosuggestion.enable = true;
      envExtra = ''
        #make sure brew is on the path for M1
        if [[ $(uname -m) == 'arm64' ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi

        # Read system-wide modifications.
        if test -f ~/.zshenv.local; then
          source ~/.zshenv.local
        fi
      '';
      initContent = ''
        # mise (replaces asdf) — activate global shims from ~/.tool-versions.
        # The `mise` binary comes from Homebrew (see modules/profiles/dev.nix).
        if command -v mise >/dev/null 2>&1; then
          eval "$(mise activate zsh)"
        fi
        export PATH="$(brew --prefix python)/libexec/bin:$PATH"
      '';
      shellAliases = {
        switch = "sudo darwin-rebuild switch --flake ${homePrefix}/${user}/nix-darwin-hm";
      };
    };
  };
}
