# d.agentHost on nix-darwin (olympus-sdk #690): a Mac with the layer on gets per-account launchers, Remote
# Control as boot-time LaunchDaemons (specs in d.agentHost.darwinDaemons, installed at the nix-darwin level), the launchctl `agents` helper, and second-brain only when enabled. Evaluated by
# extending a bare Mac Studio host (data-hub); nothing is built. Existing Macs: `just check-darwin`.
{ flake, lib }:
let
  user = "nwilliams-lucas";
  h = "/Users/${user}";
  mac = flake.darwinConfigurations.data-hub;
  withHost =
    hm:
    (mac.extendModules {
      modules = [ { home-manager.users.${user} = hm; } ];
    }).config.home-manager.users.${user};

  withSysRaw =
    hm:
    (mac.extendModules {
      modules = [ { home-manager.users.${user} = hm; } ];
    }).config;
  withSys = withSysRaw;

  # The #691 shape: one work account, second-brain off.
  work = withHost {
    d.agentHost = {
      enable = true;
      defaultAccount = "work";
      accounts.work.root = "${h}/projects/work";
      secondBrain.enable = false;
    };
  };
  # Two accounts, second-brain at its default, Codex Remote Control off for one account, no gitnexus mirror.
  both = withHost {
    d.agentHost = {
      enable = true;
      accounts = {
        personal.root = "${h}/projects/personal";
        work = {
          root = "${h}/projects/work";
          remoteControl.codex = false;
        };
      };
      gitnexus.enable = false;
    };
  };

  agents = c: lib.filterAttrs (_: a: a.enable) c.launchd.agents;
  rcAgents = c: lib.attrNames (lib.filterAttrs (n: _: lib.hasInfix "-rc-" n) (agents c));
  rc = c: lib.attrNames c.d.agentHost.darwinDaemons;
  sys = withSys {
    d.agentHost = {
      enable = true;
      defaultAccount = "work";
      accounts.work.root = "${h}/projects/work";
      secondBrain.enable = false;
    };
  };
  logs = "${h}/Library/Logs/agent-host";
  pkgNames = c: map lib.getName c.home.packages;
  agentsText = c: (lib.findFirst (p: lib.getName p == "agents") null c.home.packages).text or "";
  readProgram = a: lib.last a.ProgramArguments;
in
{
  # Off by default: the bare host has the option but no agents, launchers or activation steps.
  testDarwinOffByDefault = {
    expr =
      let
        c = mac.config.home-manager.users.${user};
      in
      [
        c.d.agentHost.enable
        (rc c)
        (lib.elem "agents" (pkgNames c))
        (c.home.activation ? agentHostDirs)
      ];
    expected = [
      false
      [ ]
      false
      false
    ];
  };
  testDarwinRemoteControlAgents = {
    expr = rc work;
    expected = [
      "claude-rc-work"
      "codex-rc-work"
    ];
  };
  testDarwinRemoteControlPerAccountToggle = {
    expr = rc both;
    expected = [
      "claude-rc-personal"
      "claude-rc-work"
      "codex-rc-personal"
    ];
  };
  testDarwinNoSystemdUnits = {
    expr = [
      work.systemd.user.services
      work.systemd.user.timers
    ];
    expected = [
      { }
      { }
    ];
  };
  testDarwinClaudeAgent = {
    expr =
      let
        a = work.d.agentHost.darwinDaemons.claude-rc-work;
      in
      [
        a.Label
        a.RunAtLoad
        a.KeepAlive
        a.WorkingDirectory
        a.StandardOutPath
        a.StandardErrorPath
        a.ThrottleInterval
        a.UserName
        a.GroupName
        a.StandardInPath
        a.EnvironmentVariables.MISE_AUTO_INSTALL
        a.EnvironmentVariables.HOME
        a.EnvironmentVariables.USER
        a.EnvironmentVariables.LOGNAME
      ];
    expected = [
      "io.olympus.agent-host.claude-rc-work"
      true
      true
      "${h}/projects/work"
      "${logs}/claude-rc-work.log"
      "${logs}/claude-rc-work.log"
      10
      user
      "staff"
      "/dev/null"
      "0"
      h
      user
      user
    ];
  };
  # No Remote Control launchd agents on macOS any more (they would need a GUI login); the old ones are retired.
  testDarwinNoRemoteControlAgents = {
    expr = [
      (rcAgents work)
      (rcAgents both)
      (lib.hasInfix "launchctl bootout \"gui/$UID/org.nix-community.home.claude-rc-work\"" work.home.activation.agentHostRetireOldAgents.data)
      (lib.hasInfix "Library/LaunchAgents/org.nix-community.home.codex-rc-work.plist" work.home.activation.agentHostRetireOldAgents.data)
      (lib.elem "setupLaunchAgents" work.home.activation.agentHostRetireOldAgents.after)
    ];
    expected = [
      [ ]
      [ ]
      true
      true
      true
    ];
  };
  # Wait until the account is logged in (credentials file, or the Keychain login's oauthAccount in .claude.json),
  # then run the launcher in server mode.
  testDarwinClaudeProgram = {
    expr =
      let
        s = readProgram work.d.agentHost.darwinDaemons.claude-rc-work;
      in
      [
        (lib.hasInfix "logged_in() { [ -f ${h}/.claude-work/.credentials.json ] || grep -q '\"oauthAccount\"' ${h}/.claude-work/.claude.json 2>/dev/null; }" s)
        (lib.hasInfix "until logged_in; do sleep 60; done" s)
        (lib.hasInfix "/bin/claude-work remote-control\n" s)
      ];
    expected = [
      true
      true
      true
    ];
  };
  # Codex drives its managed daemon, like the Linux oneshot unit, and stops it when launchd stops the agent.
  testDarwinCodexProgram = {
    expr =
      let
        s = readProgram work.d.agentHost.darwinDaemons.codex-rc-work;
      in
      [
        (lib.hasInfix "/bin/codex-work login status >/dev/null 2>&1; }" s)
        (lib.hasInfix "/bin/codex-work remote-control start || exit 1" s)
        (lib.hasInfix "trap '" s)
        (lib.hasInfix "/bin/codex-work remote-control stop; exit 0' TERM INT HUP" s)
      ];
    expected = [
      true
      true
      true
      true
    ];
  };
  testDarwinAgentPath = {
    expr =
      let
        p = lib.splitString ":" work.d.agentHost.darwinDaemons.claude-rc-work.EnvironmentVariables.PATH;
      in
      [
        (lib.head p)
        (lib.elem "/etc/profiles/per-user/${user}/bin" p)
        (lib.elem "/run/current-system/sw/bin" p)
        (lib.last p)
        (lib.any (lib.hasInfix ".nix-profile") p)
        (lib.any (lib.hasInfix "mise/shims") p)
      ];
    expected = [
      "${h}/.local/bin"
      true
      true
      "/opt/homebrew/sbin"
      false
      false
    ];
  };
  # The launchers source the per-user profile's hm-session-vars.sh (NODE_EXTRA_CA_CERTS etc.), not ~/.nix-profile.
  testDarwinLauncherSessionVars = {
    expr =
      let
        l = lib.findFirst (p: lib.getName p == "claude-work") null work.home.packages;
      in
      lib.hasInfix "/etc/profiles/per-user/${user}/etc/profile.d/hm-session-vars.sh" l.text;
    expected = true;
  };
  testDarwinCommands = {
    expr = map (n: lib.elem n (pkgNames work)) [
      "claude-work"
      "codex-work"
      "agents"
      "second-brain-sync"
    ];
    expected = [
      true
      true
      true
      false
    ];
  };
  # `agents` on launchctl: system/<label>, sudo kickstart -k, tail of the log file; no systemctl/journalctl.
  testDarwinAgentsHelper = {
    expr =
      let
        t = agentsText work;
      in
      map (x: lib.hasInfix x t) [
        "units=(claude-rc-work codex-rc-work)"
        "labels=(io.olympus.agent-host.claude-rc-work io.olympus.agent-host.codex-rc-work)"
        "domain=\"system\""
        "launchctl print \"$domain/$l\""
        "sudo launchctl kickstart -k \"$domain/$l\""
        "gui/"
        "tail -n 100 -F \"$logdir/$2.log\""
        "systemctl"
        "journalctl"
      ];
    expected = [
      true
      true
      true
      true
      true
      false
      true
      false
      false
    ];
  };
  testDarwinAccountDirsAndPromptHook = {
    expr = [
      (lib.hasInfix "install -d -m 0700 ${h}/.claude-work" work.home.activation.agentHostDirs.data)
      (lib.hasInfix "install -d -m 0755 ${logs}" work.home.activation.agentHostLogDir.data)
      (lib.elem "setupLaunchAgents" work.home.activation.agentHostLogDir.before)
      (lib.hasInfix "${h}/projects/work/*) export CLAUDE_CONFIG_DIR=${h}/.claude-work CODEX_HOME=${h}/.codex-work ;;" work.programs.zsh.initContent)
      work.home.sessionVariables.CLAUDE_CONFIG_DIR
    ];
    expected = [
      true
      true
      true
      true
      "${h}/.claude-work"
    ];
  };
  # The harness (agents, contract, hooks, settings) targets the account dirs, as on Linux (~/.claude left
  # unwired), and the memory module's default account set gains the account (it stays off unless enabled).
  testDarwinHarnessTargetsAccountDirs = {
    expr = [
      work.d.claudeHarness.dirs
      (lib.sort lib.lessThan (lib.attrNames work.d.memory.accounts))
      work.d.memory.enable
    ];
    expected = [
      [ ".claude-work" ]
      [
        "default"
        "work"
      ]
      false
    ];
  };
  # Second-brain: absent on the work host (no clone, no agent, no path override), on by default otherwise.
  testDarwinSecondBrainOff = {
    expr = [
      (work.launchd.agents ? second-brain-pull)
      (work.home.activation ? secondBrainClone)
      (lib.hasInfix ".local/share/second-brain" work.home.sessionVariables.SECOND_BRAIN_PATH)
    ];
    expected = [
      false
      false
      false
    ];
  };
  testDarwinSecondBrainOn = {
    expr =
      let
        a = both.launchd.agents.second-brain-pull.config;
      in
      [
        a.StartInterval
        a.RunAtLoad
        (lib.hasSuffix "/bin/second-brain-sync" (lib.head a.ProgramArguments))
        a.EnvironmentVariables.SECOND_BRAIN_PATH
        a.StandardOutPath
        (both.home.activation ? secondBrainClone)
      ];
    expected = [
      3600
      true
      true
      "${h}/.local/share/second-brain"
      "${logs}/second-brain-pull.log"
      true
    ];
  };
  testDarwinGitnexusToggle = {
    expr = [
      (work.home.activation ? agentHostGitnexus)
      (both.home.activation ? agentHostGitnexus)
    ];
    expected = [
      true
      false
    ];
  };
  # nix-darwin level: the specs become LaunchDaemons (run as the user), the log dir and pmset are set at activation.
  testDarwinDaemonsInstalled = {
    expr =
      let
        d = sys.launchd.daemons;
      in
      [
        (lib.filter (n: lib.hasInfix "-rc-" n) (lib.attrNames d))
        d.claude-rc-work.serviceConfig.UserName
        d.codex-rc-work.serviceConfig.UserName
        d.claude-rc-work.serviceConfig.KeepAlive
        (lib.hasInfix "/usr/bin/pmset -a sleep 0 disksleep 0 autorestart 1 womp 1" sys.system.activationScripts.postActivation.text)
        (lib.hasInfix "install -d -o ${user} -g staff -m 0755 ${logs}" sys.system.activationScripts.postActivation.text)
        (lib.hasInfix "displaysleep" sys.system.activationScripts.postActivation.text)
      ];
    expected = [
      [
        "claude-rc-work"
        "codex-rc-work"
      ]
      user
      user
      true
      true
      true
      false
    ];
  };
  # Agent-host off: no Remote Control daemons and no agent-host pmset step.
  testDarwinDaemonsOffByDefault = {
    expr = [
      (lib.filter (n: lib.hasInfix "-rc-" n) (lib.attrNames mac.config.launchd.daemons))
      (lib.hasInfix "autorestart" mac.config.system.activationScripts.postActivation.text)
    ];
    expected = [
      [ ]
      false
    ];
  };
}
