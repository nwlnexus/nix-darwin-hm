{ PROJECT_ROOT, ... }:
let
  # https://brew.sh
  initBrew = ''eval "$(/opt/homebrew/bin/brew shellenv)"'';
in
{
  imports = [
    # ./yabai
    ./general.nix
    ./dock.nix
    ./iterm2.nix
    ./finder.nix
    ./keyboard.nix
    ./limits.nix
    ./login.nix
    ./brew.nix
    ./fonts.nix
    ./mvmctl.nix
    ./packages.nix
    # ./safari.nix
    ./trackpad.nix
    ./sshd.nix
  ];

  system.stateVersion = 4;

  nix.linkInputs = true;
  nix.generateRegistryFromInputs = true;
  nix.generateNixPathFromInputs = true;

  d.hm = [
    { imports = [ ./shells.nix ]; }
  ];

  programs.zsh.interactiveShellInit = ''
    # Homebrew
    if test -e /opt/homebrew/bin/brew; then
      ${initBrew};
    fi
  '';

  environment.variables.SSH_AUTH_SOCK = "${builtins.getEnv "HOME"}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";

  security.pam.services.sudo_local.touchIdAuth = true;
  security.pki.installCACerts = true;
  security.pki.certificateFiles = [
    "${PROJECT_ROOT}/files/certs/certificate.pem"
  ];

  system.defaults.screencapture.target = "clipboard";

  system.defaults.NSGlobalDomain = {
    AppleInterfaceStyle = "Dark";
    AppleMeasurementUnits = "Inches";
    AppleTemperatureUnit = "Fahrenheit";
  };
}
