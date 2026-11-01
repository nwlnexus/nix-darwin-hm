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

        # mise shims for non-interactive shells (git hooks, scripts, agents' Bash tool), which never read
        # .zshrc and so never run `mise activate`. A plain PATH entry, not `mise activate zsh --shims`, so no
        # mise process starts per shell. Interactive shells still run `mise activate zsh` (initContent), which
        # puts the active tool versions first. Safe since auto_install is off and the global tools are pinned.
        if [[ -d "$HOME/.local/share/mise/shims" && ":$PATH:" != *":$HOME/.local/share/mise/shims:"* ]]; then
          export PATH="$HOME/.local/share/mise/shims:$PATH"
        fi

        # Read system-wide modifications.
        if test -f ~/.zshenv.local; then
          source ~/.zshenv.local
        fi
      '';
      initContent = ''
        # mise (replaces asdf) — reads the home-manager-managed global config
        # (~/.config/mise/config.toml) and per-project mise.toml / .tool-versions
        # / package.json packageManager. Binary + global config come from
        # home-manager (programs.mise, see home/default.nix).
        if command -v mise >/dev/null 2>&1; then
          eval "$(mise activate zsh)"
        fi
        export PATH="$(brew --prefix python)/libexec/bin:$PATH"
      '';
      shellAliases = {
        switch = "sudo darwin-rebuild switch --flake ${homePrefix}/${user}/projects/personal/nix-darwin-hm";
      };
    };
  };
}
