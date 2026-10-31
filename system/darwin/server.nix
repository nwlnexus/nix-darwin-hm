# Server Macs (olympus-sdk #694, H20): `d.server.enable = true` in a nix-darwin host makes the Mac a headless
# server rather than a workstation. mmini-01 uses it, and data-hub will. Off by default, so every other Mac is
# unchanged (`just check-darwin`). The home-manager side (assertions, defaults) is home/server.nix.
#
# What it does:
# - Profiles: no GUI profiles (gui-small, gui-full, business, gaming are asserted off); base and dev stay.
#   The always-on iTerm2 and Obsidian casks are dropped.
# - Tailscale: the Homebrew formula (d.profiles.base.tailscale = "formula", asserted) run by a LaunchDaemon,
#   com.tailscale.tailscaled, that starts at boot with nobody logged in. No tailscale-app, no `brew services`.
# - Power: never sleep, restart after a power failure or a freeze, wake on LAN.
# - Remote Login (sshd) is on at boot.
# - Passwordless sudo for the primary user only; Touch ID for sudo is off.
# - Everything this role adds is a LaunchDaemon. Nothing needs a GUI session or an auto-login.
# - The private `olympus-sdk` input is neither fetched nor linked (as on a work-only Mac), so a factory-fresh
#   Mac with no ssh key can build it.
#
# Not managed here: Screen Sharing, FileVault (the minis keep it off so they reboot unattended after a power
# cut; docs/hosts/mmini-01.md) and auto-login (never set; asserted unset).
{
  config,
  lib,
  user,
  ...
}:
let
  cfg = config.d.server;
  profiles = config.d.profiles;
  # Inputs a server must not reference (it has no ssh key for them).
  personalInputs = [ "olympus-sdk" ];
  tailscaled = "/opt/homebrew/bin/tailscaled";
in
{
  options.d.server = {
    enable = lib.mkEnableOption "server mode: a headless Mac with no GUI profiles, Tailscale as a system daemon, no sleep, Remote Login and passwordless sudo for the primary user";
    tailscaleDaemon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declare the com.tailscale.tailscaled LaunchDaemon. Off where something else already runs tailscaled as a system daemon (data-hub: Ansible's tailscale role, a root brew service plus a watchdog, until atlas replaces Ansible); two tailscaled cannot share the socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    home-manager.users.${user}.d.server.enable = true;

    d.profiles.base.tailscale = lib.mkDefault "formula";

    # Never sleep; restart after a power failure or a freeze; wake on network access. nix-darwin applies these
    # with `systemsetup`, which is silent when it lacks Full Disk Access, so the pmset step below sets them too.
    power = {
      sleep = {
        computer = lib.mkDefault "never";
        display = lib.mkDefault "never";
        harddisk = lib.mkDefault "never";
      };
      restartAfterPowerFailure = lib.mkDefault true;
      restartAfterFreeze = lib.mkDefault true;
    };
    networking.wakeOnLan.enable = lib.mkDefault true;

    # The Homebrew formula's tailscaled as a system daemon, the job `tailscaled install-system-daemon` would
    # write (same label, default state in /Library/Tailscale and socket /var/run/tailscaled.socket), but from the
    # formula's path. It waits for the first `brew bundle` to install the formula, so the first switch does not
    # race it. Do not also run `brew services start tailscale`: two tailscaled cannot share the socket.
    launchd.daemons.tailscaled = lib.mkIf cfg.tailscaleDaemon {
      serviceConfig = {
        Label = "com.tailscale.tailscaled";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "while [ ! -x ${tailscaled} ]; do sleep 5; done; exec ${tailscaled}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/var/log/tailscaled.log";
        StandardErrorPath = "/var/log/tailscaled.log";
      };
    };

    # Passwordless sudo for the primary user only (owner decision 11, #694). Runner jobs run as a separate
    # unprivileged user and never get this.
    security.sudo.extraConfig = ''
      ${user} ALL=(ALL) NOPASSWD: ALL
    '';
    # Touch ID for sudo is pointless without a console user and the line above makes it moot.
    security.pam.services.sudo_local.touchIdAuth = lib.mkForce false;

    # Power through pmset (applies without Full Disk Access) and Remote Login through launchd, not
    # `systemsetup -setremotelogin`, which needs Full Disk Access. Both are idempotent.
    system.activationScripts.postActivation.text = ''
      echo "configuring server power (pmset)..." >&2
      /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1 womp 1

      if ! /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
        echo "enabling Remote Login (sshd)..." >&2
        /bin/launchctl enable system/com.openssh.sshd
        /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
      fi
    '';

    environment.etc = lib.listToAttrs (
      map (name: lib.nameValuePair "nix/inputs/${name}" { enable = false; }) personalInputs
    );

    assertions = [
      {
        assertion = !profiles.gui-small.enable;
        message = "d.server: gui-small is a GUI profile; a server runs none.";
      }
      {
        assertion = !profiles.gui-full.enable;
        message = "d.server: gui-full is a GUI profile (the Claude Desktop app, the 1Password app); a server runs none.";
      }
      {
        assertion = !profiles.business.enable;
        message = "d.server: business is a GUI profile; a server runs none.";
      }
      {
        assertion = !profiles.gaming.enable;
        message = "d.server: gaming is a GUI profile; a server runs none.";
      }
      {
        assertion = profiles.base.tailscale == "formula";
        message = "d.server: Tailscale must be the Homebrew formula run as a system daemon (d.profiles.base.tailscale = \"formula\"), never the app.";
      }
      {
        assertion = config.power.sleep.computer == "never";
        message = "d.server: the computer must never sleep (power.sleep.computer = \"never\").";
      }
      {
        assertion = config.system.defaults.loginwindow.autoLoginUser == null;
        message = "d.server: no auto-login; every service is a LaunchDaemon.";
      }
    ];
  };
}
