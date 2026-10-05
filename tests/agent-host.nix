# Per-account agent tooling on Linux agent hosts.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  svc = hm.systemd.user.services;
  h = "/home/nwilliams-lucas";
  pkgNames = map lib.getName hm.home.packages;
  # home-manager normalizes unit values to lists; read either form as one string.
  str = v: lib.concatStringsSep " " (map toString (lib.toList v));
in
{
  testRemoteControlUnits = {
    expr = lib.sort lib.lessThan (lib.attrNames (lib.filterAttrs (n: _: lib.hasInfix "-rc-" n) svc));
    expected = [
      "claude-rc-personal"
      "claude-rc-work"
      "codex-rc-personal"
      "codex-rc-personal-health"
      "codex-rc-work"
      "codex-rc-work-health"
    ];
  };
  # systemd only sees the daemon's oneshot launcher, so a timer restarts the
  # unit when the self-updating daemon stops running. Claude runs in the
  # foreground under Restart=always and needs none.
  testCodexHealthTimers = {
    expr = lib.sort lib.lessThan (lib.attrNames hm.systemd.user.timers);
    expected = [
      "codex-rc-personal-health"
      "codex-rc-work-health"
    ];
  };
  testCodexHealthCheck = {
    expr =
      let
        u = svc.codex-rc-work-health.Service;
        t = hm.systemd.user.timers.codex-rc-work-health;
        script = builtins.readFile (str u.ExecStart);
      in
      [
        (str u.Type)
        (lib.hasSuffix "/bin/test -f ${h}/.codex-work/auth.json" (str u.ExecCondition))
        (lib.hasInfix "/bin/codex-work app-server daemon version" script)
        (lib.hasInfix "systemctl --user restart codex-rc-work.service" script)
        (str t.Timer.OnUnitActiveSec)
        t.Install.WantedBy
      ];
    expected = [
      "oneshot"
      true
      true
      true
      "5min"
      [ "timers.target" ]
    ];
  };
  testClaudeWorkingDirectory = {
    expr = (str svc.claude-rc-work.Service.WorkingDirectory);
    expected = "${h}/projects/work";
  };
  testClaudeServerMode = {
    expr = lib.hasSuffix "/bin/claude-work remote-control" (str svc.claude-rc-work.Service.ExecStart);
    expected = true;
  };
  # Codex 0.159's foreground `remote-control` fails its socket-parent check;
  # the managed daemon (`start`/`stop`) works, so the unit drives that.
  testCodexDaemonManaged = {
    expr =
      let
        u = svc.codex-rc-personal.Service;
      in
      [
        (u.Type or null)
        (u.RemainAfterExit or false)
        (lib.hasSuffix "/bin/codex-personal remote-control start" (str (u.ExecStart or "")))
        (lib.hasSuffix "/bin/codex-personal remote-control stop" (str (u.ExecStop or "")))
        (u.Restart or null)
      ];
    expected = [
      "oneshot"
      true
      true
      true
      "on-failure"
    ];
  };
  testClaudeCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.claude-work/.credentials.json" (
      str svc.claude-rc-work.Service.ExecCondition
    );
    expected = true;
  };
  testCodexCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.codex-personal/auth.json" (
      str svc.codex-rc-personal.Service.ExecCondition
    );
    expected = true;
  };
  testRestartAndBoot = {
    expr = [
      (str svc.claude-rc-personal.Service.Restart)
      svc.claude-rc-personal.Install.WantedBy
    ];
    expected = [
      "always"
      [ "default.target" ]
    ];
  };
  testDefaultAccount = {
    expr = [
      hm.home.sessionVariables.CLAUDE_CONFIG_DIR
      hm.home.sessionVariables.CODEX_HOME
    ];
    expected = [
      "${h}/.claude-personal"
      "${h}/.codex-personal"
    ];
  };
  # The account follows $PWD at every prompt (after direnv), so nested repos
  # with their own .envrc keep the right account.
  testAccountPromptHook = {
    expr = map (x: lib.hasInfix x hm.programs.zsh.initContent) [
      "precmd_functions+=(_agent_host_account)"
      "${h}/projects/work/*) export CLAUDE_CONFIG_DIR=${h}/.claude-work CODEX_HOME=${h}/.codex-work ;;"
      "${h}/projects/personal/*) export CLAUDE_CONFIG_DIR=${h}/.claude-personal CODEX_HOME=${h}/.codex-personal ;;"
      "*) export CLAUDE_CONFIG_DIR=${h}/.claude-personal CODEX_HOME=${h}/.codex-personal ;;"
    ];
    expected = [
      true
      true
      true
      true
    ];
  };
  # The tree-level .envrc no longer carries the account (nearest-.envrc-only).
  testDirenvHooksCarryNoAccount = {
    expr = lib.hasInfix "CLAUDE_CONFIG_DIR" hm.home.file."direnv-hook-work".text;
    expected = false;
  };
  testBrainCommandLinked = {
    expr = hm.home.file ? ".claude-work/commands/brain.md";
    expected = true;
  };
  testCommands = {
    expr = map (n: builtins.elem n pkgNames) [
      "claude-personal"
      "claude-work"
      "codex-personal"
      "codex-work"
      "agents"
    ];
    expected = [
      true
      true
      true
      true
      true
    ];
  };
  # Codex refuses to start when CODEX_HOME doesn't exist ("that path does not exist").
  testConfigDirsCreated = {
    expr =
      map (d: lib.hasInfix "install -d -m 0700 ${h}/${d}" (hm.home.activation.agentHostDirs.data or ""))
        [
          ".claude-personal"
          ".claude-work"
          ".codex-personal"
          ".codex-work"
        ];
    expected = [
      true
      true
      true
      true
    ];
  };
}
