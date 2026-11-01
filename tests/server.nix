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

  # ---- d.server.ciRunner and d.server.linuxVm (olympus-sdk #694, H20) ----

  # Both modules evaluate with their defaults on mmini-01 and nothing is switched on for the control Mac.
  testRunnerVmOptions = {
    expr =
      let
        r = sys.d.server.ciRunner;
        v = sys.d.server.linuxVm;
      in
      {
        runner = {
          inherit (r)
            enable
            org
            group
            labels
            appIdFile
            installationIdFile
            privateKeyFile
            user
            workDir
            ;
        };
        vm = {
          inherit (v)
            enable
            name
            cpus
            memoryGiB
            diskGiB
            bridgeInterface
            image
            ;
        };
        control = [
          ctl.d.server.ciRunner.enable
          ctl.d.server.linuxVm.enable
          (ctl.launchd.daemons ? ci-runner)
          (ctl.launchd.daemons ? server-vm)
        ];
      };
    expected = {
      runner = {
        enable = true;
        org = "nwlnexus";
        group = "olympus-ci";
        labels = [
          "self-hosted"
          "macOS"
          "ARM64"
          "macos-arm64"
        ];
        appIdFile = "/var/root/ci-runner/app-id";
        installationIdFile = "/var/root/ci-runner/installation-id";
        privateKeyFile = "/var/root/ci-runner/private-key.pem";
        user = "_ghrunner";
        workDir = "/var/lib/ci-runner";
      };
      vm = {
        enable = true;
        name = "mmini-01-vm";
        cpus = 6;
        memoryGiB = 12;
        diskGiB = 150;
        bridgeInterface = "en0";
        image = "ghcr.io/cirruslabs/ubuntu:24.04";
      };
      control = [
        false
        false
        false
        false
      ];
    };
  };

  # The runner daemon: root (no UserName), kept alive, the credentials by path only, the runner pinned in the store.
  testRunnerDaemon = {
    expr =
      let
        d = sys.launchd.daemons.ci-runner.serviceConfig;
        e = d.EnvironmentVariables;
      in
      {
        inherit (d) Label RunAtLoad KeepAlive;
        root = (d.UserName or null) == null;
        argv = builtins.length d.ProgramArguments;
        # Waits for the /nix volume before exec'ing the store path (boot ordering).
        waitsForStore = lib.hasPrefix "/bin/wait4path /nix/store && exec /nix/store/" (
          lib.last d.ProgramArguments
        );
        user = e.CI_USER;
        labels = e.CI_LABELS;
        runnerPinned = lib.hasInfix "actions-runner-osx-arm64-" e.CI_RUNNER_DIR;
        keyPath = e.CI_PRIVATE_KEY_FILE;
        noSecretInEnv = !(lib.any (lib.hasInfix "BEGIN") (lib.attrValues e));
      };
    expected = {
      Label = "io.olympus.ci-runner";
      RunAtLoad = true;
      KeepAlive = true;
      root = true;
      argv = 3;
      waitsForStore = true;
      user = "_ghrunner";
      labels = "self-hosted,macOS,ARM64,macos-arm64";
      runnerPinned = true;
      keyPath = "/var/root/ci-runner/private-key.pem";
      noSecretInEnv = true;
    };
  };

  # The runner user: hidden, fixed id in the service range, no shell, not an admin, not in sudoers, no access to the
  # primary user's home.
  testRunnerUserUnprivileged = {
    expr =
      let
        u = sys.users.users._ghrunner;
        everyone = lib.concatStringsSep "\n" [
          (sudoers sys)
          (sys.environment.etc."sudoers".text or "")
        ];
        adminMembers = sys.users.groups.admin.members or [ ];
        wheelMembers = sys.users.groups.wheel.members or [ ];
      in
      {
        inherit (u) uid gid isHidden;
        shell = u.shell;
        known = [
          (lib.elem "_ghrunner" sys.users.knownUsers)
          (lib.elem "_ghrunner" sys.users.knownGroups)
        ];
        groupGid = sys.users.groups._ghrunner.gid;
        inSudoers = lib.hasInfix "_ghrunner" everyone;
        admin = lib.elem "_ghrunner" (adminMembers ++ wheelMembers);
        homeUnderPrimary = lib.hasPrefix "/Users/" u.home;
        home = u.home;
      };
    expected = {
      uid = 533;
      gid = 533;
      isHidden = true;
      shell = null;
      known = [
        true
        true
      ];
      groupGid = 533;
      inSudoers = false;
      admin = false;
      homeUnderPrimary = false;
      home = "/var/lib/ci-runner/home";
    };
  };

  # The JIT config is passed in the environment only: the script names the variable, never the --jitconfig flag, and
  # the daemon's argv is just the script. The bearer tokens reach curl on stdin. Sources are read, not built.
  testRunnerJitNotOnArgv =
    let
      script = builtins.readFile ../scripts/server/ci-runner-loop.sh;
      code = lib.filter (l: !(lib.hasPrefix "#" (lib.trim l))) (lib.splitString "\n" script);
      codeText = lib.concatStringsSep "\n" code;
    in
    {
      expr = {
        envVar = lib.hasInfix "ACTIONS_RUNNER_INPUT_JITCONFIG=$jit" codeText;
        noFlag = !(lib.hasInfix "--jitconfig" codeText);
        noJitInArgv =
          !(lib.hasInfix "run.sh \"$jit\"" codeText) && !(lib.hasInfix "--jitconfig $jit" codeText);
        bearerOnStdin = lib.hasInfix "curl -K -" codeText || lib.hasInfix "-K - -X" codeText;
        noBearerArg = !(lib.hasInfix "-H \"Authorization" codeText);
        generatesJit = lib.hasInfix "/actions/runners/generate-jitconfig" codeText;
        rs256 = lib.hasInfix "openssl dgst -sha256 -sign" codeText;
        nice = lib.hasInfix "nice -n" codeText;
        wipes = lib.hasInfix "find \"$CI_WORK_DIR/home\" -mindepth 1 -maxdepth 1 ! -name Library -exec rm -rf {} +" codeText;
      };
      expected = {
        envVar = true;
        noFlag = true;
        noJitInArgv = true;
        bearerOnStdin = true;
        noBearerArg = true;
        generatesJit = true;
        rs256 = true;
        nice = true;
        wipes = true;
      };
    };

  # The Tart daemon: runs as the primary user, headless on the bridged NIC, KeepAlive, logs under /var/log.
  testVmDaemon = {
    expr =
      let
        d = sys.launchd.daemons.server-vm.serviceConfig;
        e = d.EnvironmentVariables;
        runScript = builtins.readFile ../scripts/server/vm-run.sh;
      in
      {
        inherit (d)
          Label
          UserName
          RunAtLoad
          KeepAlive
          StandardOutPath
          ;
        name = e.VM_NAME;
        bridge = e.VM_BRIDGE;
        tart = lib.hasSuffix "/bin/tart" e.TART_BIN && lib.hasInfix "-tart-" e.TART_BIN;
        marker = e.VM_MARKER;
        runs = lib.hasInfix "exec \"$TART_BIN\" run --no-graphics \"--net-bridged=$VM_BRIDGE\" \"$VM_NAME\"" runScript;
      };
    expected = {
      Label = "io.olympus.server-vm";
      UserName = user;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/var/log/server-vm.log";
      name = "mmini-01-vm";
      bridge = "en0";
      tart = true;
      marker = "/Users/${user}/.tart/mmini-01-vm.provisioned";
      runs = true;
    };
  };

  # Tart from nixpkgs (the cirruslabs tap no longer loads); the provisioning command is installed, not run on a switch.
  testVmTartAndProvision = {
    expr = {
      brew = lib.elem "cirruslabs/cli/tart" (brews sys);
      tart = lib.any (p: lib.getName p == "tart") sys.environment.systemPackages;
      command = lib.any (p: lib.getName p == "server-vm-provision") sys.environment.systemPackages;
      notInActivation = !(lib.hasInfix "server-vm-provision" (postActivation sys));
      controlHasNoTart = !(lib.elem "cirruslabs/cli/tart" (brews ctl));
    };
    expected = {
      brew = false;
      tart = true;
      command = true;
      notInActivation = true;
      controlHasNoTart = true;
    };
  };

  # The provisioning script hardens the image before the marker is written, and does not bridge the NIC itself.
  testVmProvisionHardens =
    let
      s = builtins.readFile ../scripts/server/vm-provision.sh;
    in
    {
      expr = map (lib.flip lib.hasInfix s) [
        "PasswordAuthentication no"
        "AllowUsers ansible"
        "passwd -l admin"
        "--random-mac"
        "admin password login is refused"
        "dhcp-identifier=mac"
      ];
      expected = [
        true
        true
        true
        true
        true
        true
      ];
    };
  testVmProvisionNeverBridges = {
    expr = lib.hasInfix "net-bridged" (builtins.readFile ../scripts/server/vm-provision.sh);
    expected = false;
  };

  # Without d.server the modules refuse to switch on (the control Mac is a workstation).
  testRunnerVmAssertWithoutServer = {
    expr = lib.sort lib.lessThan (
      failing
        (flake.darwinConfigurations.nwl-mstudio.extendModules {
          modules = [
            {
              d.server.ciRunner.enable = true;
              d.server.linuxVm.enable = true;
            }
          ];
        }).config
    );
    expected = [
      "d.server.ciRunner needs d.server.enable: the runner is part of the server role."
      "d.server.linuxVm needs d.server.enable: the VM is part of the server role."
    ];
  };
  testRunnerAssertUser = {
    expr = failing (with' {
      d.server.ciRunner.user = lib.mkForce user;
    });
    expected = [
      "d.server.ciRunner.user must be a dedicated unprivileged user, not root or the primary user."
    ];
  };
  testRunnerAssertCredentialsOutsideWorkDir = {
    expr = failing (with' {
      d.server.ciRunner.privateKeyFile = "/var/lib/ci-runner/key.pem";
    });
    expected = [
      "d.server.ciRunner: the credential files must live outside workDir, which is wiped and owned by the runner user."
    ];
  };

  # data-hub (olympus-sdk #701): compute like the minis, with a larger VM; Tailscale stays Ansible's, Postgres is gone.
  testDataHubCompute = {
    expr =
      let
        dh = flake.darwinConfigurations.data-hub.config;
      in
      {
        inherit (dh.d.server) tailscaleDaemon;
        runner = dh.d.server.ciRunner.enable;
        vm = {
          inherit (dh.d.server.linuxVm)
            enable
            name
            cpus
            memoryGiB
            ;
        };
        daemons = map (n: dh.launchd.daemons ? ${n}) [
          "ci-runner"
          "server-vm"
          "tailscaled"
        ];
        postgres = lib.elem "postgresql@16" (brews dh);
        failing = failing dh;
      };
    expected = {
      tailscaleDaemon = false;
      runner = true;
      vm = {
        enable = true;
        name = "data-hub-vm";
        cpus = 8;
        memoryGiB = 32;
      };
      daemons = [
        true
        true
        false
      ];
      postgres = false;
      failing = [ ];
    };
  };
}
