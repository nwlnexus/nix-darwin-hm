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

    brews = [ ];

    # Casks installed on all macOS hosts.
    casks = [
      "obsidian"
    ];

    taps = [ ];
  };
}
