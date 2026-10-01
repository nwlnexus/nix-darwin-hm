# Linuxbrew on standalone (non-NixOS) hosts, for formulae nixpkgs lacks or
# lags badly on. Nix stays the default: brew's bin is appended to PATH (so
# its own deps never shadow Nix/mise), and a switch only installs what's
# missing -- no upgrades (`brew upgrade` when wanted), no cleanup.
{
  config,
  lib,
  ...
}:
let
  cfg = config.d.linuxbrew;
  brew = "${cfg.prefix}/bin/brew";
in
{
  options.d.linuxbrew = {
    enable = lib.mkEnableOption "declarative Linuxbrew formulae (brew bundle, install-only)";

    prefix = lib.mkOption {
      type = lib.types.str;
      default = "/home/linuxbrew/.linuxbrew";
    };

    # Non-official taps, emitted as `tap "...", trusted: true` (Homebrew 6+
    # tap trust; same rule as homebrew.extraConfig on the Macs).
    taps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    brews = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".Brewfile".text = lib.concatStrings (
      map (t: ''
        tap "${t}", trusted: true
      '') cfg.taps
      ++ map (b: ''
        brew "${b}"
      '') cfg.brews
    );

    home.sessionVariables = {
      HOMEBREW_PREFIX = cfg.prefix;
      HOMEBREW_CELLAR = "${cfg.prefix}/Cellar";
      HOMEBREW_REPOSITORY = "${cfg.prefix}/Homebrew";
    };

    # Appended last (home.sessionPath appends to PATH).
    home.sessionPath = lib.mkAfter [
      "${cfg.prefix}/bin"
      "${cfg.prefix}/sbin"
    ];

    # Fail-soft: a brew or network hiccup must not abort the rest of the
    # activation (the op-secrets lesson).
    home.activation.linuxbrewBundle = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -x ${brew} ]; then
        if ! run env HOMEBREW_NO_AUTO_UPDATE=1 ${brew} bundle install --file=${config.home.homeDirectory}/.Brewfile --no-upgrade; then
          warnEcho "linuxbrew: brew bundle failed; continuing (retry: brew bundle install --file ~/.Brewfile)"
        fi
      else
        warnEcho "linuxbrew: ${brew} not found; skipping (scripts/bootstrap-agent-host.sh installs it)"
      fi
    '';
  };
}
