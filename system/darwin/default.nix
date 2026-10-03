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

  # mnemosyne retirement, root-owned leftovers (user-level ones are in
  # home/cli/claude/default.nix). Idempotent: every step is a no-op once done.
  # Delete once every host has switched.
  system.activationScripts.postActivation.text = ''
    rm -f /etc/nix/r2-cache.conf
    creds=/var/root/.aws/credentials
    if [ -f "$creds" ] && grep -q '^\[nwlnexus-r2\]' "$creds"; then
      tmp="$(mktemp)"
      awk '/^\[/ { skip = ($0 == "[nwlnexus-r2]") } !skip' "$creds" > "$tmp" \
        && cat "$tmp" > "$creds"
      rm -f "$tmp"
      # Drop the file entirely if nothing but whitespace is left.
      grep -q '[^[:space:]]' "$creds" || rm -f "$creds"
    fi
  '';

  system.defaults.screencapture.target = "clipboard";

  system.defaults.NSGlobalDomain = {
    AppleInterfaceStyle = "Dark";
    AppleMeasurementUnits = "Inches";
    AppleTemperatureUnit = "Fahrenheit";
  };
}
