# Server role (olympus-sdk #694, H20): mmini-01 as evaluated from the flake (d.server, system/darwin/server.nix and
# home/server.nix). Nothing is built. A personal Mac (nwl-mstudio) is the control: the same probes must find the
# workstation config there, so a probe that can never fire fails here instead of passing silently.
{ flake, lib }:
let
  user = "nwilliams-lucas";
  mini = flake.darwinConfigurations.mmini-01;
  sys = mini.config;
  hm = sys.home-manager.users.${user};
  ctl = flake.darwinConfigurations.nwl-mstudio.config;

  brews = c: map (b: b.name) c.homebrew.brews;
  casks = c: map (k: k.name) c.homebrew.casks;
  failing = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
  with' = module: (mini.extendModules { modules = [ module ]; }).config;
  sudoers = c: c.environment.etc."sudoers.d/10-nix-darwin-extra-config".text or "";
  postActivation = c: c.system.activationScripts.postActivation.text;
in
{
  # The sudoers drop-in: one line, for the primary user only.
  testServerSudoers = {
    expr = lib.filter (lib.hasInfix "NOPASSWD") (lib.splitString "\n" (sudoers sys));
    expected = [ "${user} ALL=(ALL) NOPASSWD: ALL" ];
  };
  testServerSudoersControl = {
    expr = lib.hasInfix "NOPASSWD" (sudoers ctl);
    expected = false;
  };

  # Touch ID for sudo is off on the server (the control keeps it).
  testServerNoTouchIdSudo = {
    expr = [
      sys.security.pam.services.sudo_local.touchIdAuth
      ctl.security.pam.services.sudo_local.touchIdAuth
    ];
    expected = [
      false
      true
    ];
  };

  # Tailscale: the Homebrew formula (never the app cask) run by the com.tailscale.tailscaled system daemon,
  # started at load and kept alive.
  testServerTailscaleFormula = {
    expr = [
      (lib.elem "tailscale" (brews sys))
      (lib.elem "tailscale-app" (casks sys))
    ];
    expected = [
      true
      false
    ];
  };
  testServerTailscaleDaemon = {
    expr =
      let
        d = sys.launchd.daemons.tailscaled.serviceConfig;
      in
      {
        inherit (d) Label RunAtLoad KeepAlive;
        execsFormula = lib.hasInfix "exec /opt/homebrew/bin/tailscaled" (lib.last d.ProgramArguments);
        plist = sys.launchd.daemons.tailscaled.serviceConfig.Label + ".plist";
      };
    expected = {
      Label = "com.tailscale.tailscaled";
      RunAtLoad = true;
      KeepAlive = true;
      execsFormula = true;
      plist = "com.tailscale.tailscaled.plist";
    };
  };
  testServerTailscaleDaemonControl = {
    expr = ctl.launchd.daemons ? tailscaled;
    expected = false;
  };

  # No GUI profile: base and dev only.
  testServerProfiles = {
    expr = lib.mapAttrs (_: p: p.enable) (
      lib.getAttrs [
        "base"
        "dev"
        "gui-small"
        "gui-full"
        "business"
        "gaming"
      ] sys.d.profiles
    );
    expected = {
      base = true;
      dev = true;
      gui-small = false;
      gui-full = false;
      business = false;
      gaming = false;
    };
  };

  # No GUI casks from the always-on lists (iTerm2, Obsidian) and none of the GUI profile casks; the control has them.
  testServerNoGuiCasks = {
    expr =
      let
        gui = [
          "iterm2"
          "obsidian"
          "sublime-text"
          "1password@beta"
        ];
      in
      {
        server = lib.filter (c: lib.elem c gui) (casks sys);
        control = lib.sort lib.lessThan (lib.filter (c: lib.elem c gui) (casks ctl));
      };
    expected = {
      server = [ ];
      control = [
        "1password@beta"
        "iterm2"
        "obsidian"
        "sublime-text"
      ];
    };
  };

  # Power: never sleep, restart after a power failure or freeze, wake on LAN.
  testServerPower = {
    expr = {
      sleep = sys.power.sleep;
      inherit (sys.power) restartAfterPowerFailure restartAfterFreeze;
      wol = sys.networking.wakeOnLan.enable;
    };
    expected = {
      sleep = {
        computer = "never";
        display = "never";
        harddisk = "never";
        allowSleepByPowerButton = null;
      };
      restartAfterPowerFailure = true;
      restartAfterFreeze = true;
      wol = true;
    };
  };

  # pmset sets it too (systemsetup is silent without Full Disk Access). Remote Login goes through launchctl;
  # nothing in this role calls `systemsetup` itself (nix-darwin's own power step does, in its own script).
  testServerActivation = {
    expr =
      let
        t = postActivation sys;
      in
      [
        (lib.hasInfix "/usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1 womp 1" t)
        (lib.hasInfix "launchctl enable system/com.openssh.sshd" t)
        (lib.hasInfix "launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist" t)
        (lib.hasInfix "systemsetup" t)
        (lib.hasInfix "pmset" (postActivation ctl))
      ];
    expected = [
      true
      true
      true
      false
      false
    ];
  };

  # No memory client, second-brain or agent-host layer; no 1Password app integration; no private input.
  testServerNothingPersonal = {
    expr = [
      hm.d.memory.enable
      (hm.d.agentHost.enable or false)
      hm.d.apps.onepassword.gui
      hm.d.claudeHarness.settings.autoModeFile
      hm.d.claudeHarness.telemetry.file
      sys.environment.etc."nix/inputs/olympus-sdk".enable
    ];
    expected = [
      false
      false
      false
      null
      null
      false
    ];
  };

  # Nothing the role adds requires a GUI session: the only LaunchAgent is the dev profile's cargo-sweep (not added
  # by d.server), and there is no auto-login user.
  testServerNoLaunchAgents = {
    expr = [
      (lib.attrNames (lib.filterAttrs (_: a: a.enable) hm.launchd.agents))
      (sys.system.defaults.loginwindow.autoLoginUser or null)
    ];
    expected = [
      [ "cargo-sweep" ]
      null
    ];
  };

  # The host as shipped passes every assertion.
  testServerNoFailingAssertions = {
    expr = failing sys;
    expected = [ ];
  };

  # Each assertion fires.
  testServerAssertGuiProfiles = {
    expr = lib.sort lib.lessThan (
      failing (with' {
        d.profiles = {
          gui-small.enable = true;
          gui-full.enable = true;
          business.enable = true;
          gaming.enable = true;
        };
      })
    );
    expected = [
      "d.server: business is a GUI profile; a server runs none."
      "d.server: gaming is a GUI profile; a server runs none."
      "d.server: gui-full is a GUI profile (the Claude Desktop app, the 1Password app); a server runs none."
      "d.server: gui-small is a GUI profile; a server runs none."
    ];
  };
  testServerAssertMemory = {
    expr = failing (with' {
      home-manager.users.${user}.d.memory = {
        enable = true;
        host = "mmini-01";
      };
    });
    expected = [
      "${user} profile: d.server: the memory-gateway client (d.memory) is personal; leave it off on a server."
    ];
  };
  testServerAssertTailscaleApp = {
    expr = failing (with' {
      d.profiles.base.tailscale = lib.mkForce "app";
    });
    expected = [
      "d.server: Tailscale must be the Homebrew formula run as a system daemon (d.profiles.base.tailscale = \"formula\"), never the app."
    ];
  };
  testServerAssertSleep = {
    expr = failing (with' {
      power.sleep.computer = lib.mkForce 30;
    });
    expected = [ "d.server: the computer must never sleep (power.sleep.computer = \"never\")." ];
  };
  testServerAssertAutoLogin = {
    expr = failing (with' {
      system.defaults.loginwindow.autoLoginUser = "${user}";
    });
    expected = [ "d.server: no auto-login; every service is a LaunchDaemon." ];
  };
}
