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
    ];

    # libkrun/krun is a third-party tap. Homebrew 6.0 gates untrusted taps, and
    # libkrun pulls in `libkrun/krun/virglrenderer` as a dependency (not
    # fully-qualified above), so the bundle refuses it from an untrusted tap.
    # nix-darwin's `taps` option can't emit `trusted: true`, so declare the tap
    # as a verbatim Brewfile line that both taps AND trusts it (covering the
    # dependency too). Same pattern as modules/profiles/base.nix for
    # nwlnexus/olympus. See https://docs.brew.sh/Tap-Trust
    extraConfig = ''
      tap "libkrun/krun", trusted: true
    '';
  };
}
