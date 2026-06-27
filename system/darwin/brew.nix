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

    # slp/krun is a third-party tap. Homebrew 6.0 gates untrusted taps, and
    # libkrun pulls in `slp/krun/virglrenderer` as a dependency (not
    # fully-qualified above), so the bundle refuses it from an untrusted tap.
    # nix-darwin's `taps` option can't emit `trusted: true`, so declare the tap
    # as a verbatim Brewfile line that both taps AND trusts it (covering the
    # dependency too). Same pattern as modules/profiles/base.nix for
    # nwlnexus/olympus. See https://docs.brew.sh/Tap-Trust
    extraConfig = ''
      tap "slp/krun", trusted: true
    '';
  };
}
