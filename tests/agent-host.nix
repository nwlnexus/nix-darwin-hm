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
      "codex-rc-work"
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
  # Foreground form, so systemd supervises it (not `remote-control start`).
  testCodexForeground = {
    expr = lib.hasSuffix "/bin/codex-personal remote-control" (
      str svc.codex-rc-personal.Service.ExecStart
    );
    expected = true;
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
  testWorkDirenv = {
    expr =
      lib.hasInfix ''export CLAUDE_CONFIG_DIR="${h}/.claude-work"''
        hm.home.file."direnv-hook-work".text;
    expected = true;
  };
  testPersonalDirenvNoWork = {
    expr = lib.hasInfix ".claude-work" hm.home.file."direnv-hook-personal".text;
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
}
