{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      # Run `brew bundle --cleanup` on every rebuild: remove any tap, brew, or
      # cask NOT declared in this config. Keeps Homebrew fully declarative and
      # prevents stale taps (e.g. a renamed slp/krun) from lingering on disk and
      # colliding with their replacements ("Formulae found in multiple taps").
      # Trade-off: also removes anything installed manually with `brew install`
      # outside Nix.
      cleanup = "uninstall";
    };
    caskArgs = {
      fontdir = "~/Library/Fonts";
    };

    brews = [
      # libkrun runtime for mvmctl's macOS microVM backends (Apple
      # Virtualization / Hypervisor.framework). virglrenderer is pulled in
      # automatically as a libkrun dependency. See ./mvmctl.nix.
      # NOTE: the upstream `slp/krun` tap was renamed/redirected to
      # `libkrun/krun`; using the old name leaves both taps present and
      # Homebrew errors with "Formulae found in multiple taps".
      "libkrun/krun/libkrun"
      "libkrun/krun/libkrunfw"
      "libkrun/krun/gvproxy"
    ];

    # Casks installed on all macOS hosts.
    casks = [
      "obsidian"
      # Secrets scanner. Prefer the upstream tap cask over homebrew-core's
      # formula of the same name: both ship `betterleaks`, and having the cask
      # installed while the Brewfile asks for the formula makes `brew bundle`
      # load the cask (upgrade/cleanup) and then fail the formula link.
      # Used as a pre-commit gate — see home/cli/git/default.nix.
      "betterleaks/tap/betterleaks"
    ];

    # Third-party taps. Homebrew 6.0 gates untrusted taps; nix-darwin's `taps`
    # option can't emit `trusted: true`, so declare them as verbatim Brewfile
    # lines that both tap AND trust. Same pattern as modules/profiles/base.nix
    # / dev.nix. Critical under darwin-rebuild: activate runs
    # `sudo --user=… --set-home brew bundle` without XDG_CONFIG_HOME, so brew
    # reads ~/.homebrew/trust.json — interactive `brew trust` (which wrote
    # ~/.config/homebrew/trust.json) does not apply. See https://docs.brew.sh/Tap-Trust
    extraConfig = ''
      tap "libkrun/krun", trusted: true
      tap "betterleaks/tap", trusted: true
    '';
  };
}
