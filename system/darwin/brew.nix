{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
    };
    caskArgs = {
      fontdir = "~/Library/Fonts";
    };

    brews = [
      # libkrun runtime for mvmctl's macOS microVM backends (Apple
      # Virtualization / Hypervisor.framework). virglrenderer is pulled in
      # automatically as a libkrun dependency. See ./mvmctl.nix.
      "slp/krun/libkrun"
      "slp/krun/libkrunfw"
      "slp/krun/gvproxy"
    ];

    # Casks installed on all macOS hosts.
    casks = [
      "obsidian"
    ];

    # NOTE: slp/krun is a third-party tap. Homebrew gates untrusted taps, so a
    # fresh machine needs a one-time `brew trust slp/krun` (run as your user)
    # before the first `darwin-rebuild switch`, or the brew bundle will refuse
    # to install these formulae.
    taps = [ "slp/krun" ];
  };
}
