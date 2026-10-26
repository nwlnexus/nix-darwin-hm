# Agent harness from agent-skills (home/cli/claude/harness.nix): agents/ and the session-contract block in
# CLAUDE.md, for the account dirs on the agent host (never ~/.claude there) and ~/.claude on a Mac.
{ flake, lib }:
let
  host = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  mac = flake.darwinConfigurations.NWL-MMINI.config.home-manager.users.nwilliams-lucas;
  h = "/home/nwilliams-lucas";
  m = "/Users/nwilliams-lucas";
  contract = c: c.home.activation.claudeSessionContract.data or "";
in
{
  testHarnessAgentsFound = {
    expr = lib.elem "claim-verifier.md" host.d.claudeHarness.agents;
    expected = true;
  };
  testHarnessHostDirs = {
    expr = host.d.claudeHarness.dirs;
    expected = [
      ".claude-personal"
      ".claude-work"
    ];
  };
  testHarnessHostAgents = {
    expr = map (f: host.home.file ? ${f}) [
      ".claude-personal/agents/claim-verifier.md"
      ".claude-work/agents/claim-verifier.md"
      ".claude/agents/claim-verifier.md"
    ];
    expected = [
      true
      true
      false
    ];
  };
  testHarnessHostContract = {
    expr = map (f: lib.hasInfix f (contract host)) [
      " ${h}/.claude-personal/CLAUDE.md"
      " ${h}/.claude-work/CLAUDE.md"
      " ${h}/.claude/CLAUDE.md"
      "fragments/session-contract.md"
    ];
    expected = [
      true
      true
      false
      true
    ];
  };
  testHarnessContractAfterAccountDirs = {
    expr = lib.elem "agentHostDirs" host.home.activation.claudeSessionContract.after;
    expected = true;
  };
  # The long-task skill reaches the account dirs through the existing skills wiring.
  testHarnessHostSkill = {
    expr = map (f: host.home.file ? ${f}) [
      ".claude-personal/skills/long-task"
      ".claude-work/skills/long-task"
    ];
    expected = [
      true
      true
    ];
  };
  testHarnessMac = {
    expr = [
      mac.d.claudeHarness.dirs
      (mac.home.file ? ".claude/agents/claim-verifier.md")
      (mac.home.file ? ".claude/skills/long-task")
      (lib.hasInfix " ${m}/.claude/CLAUDE.md" (contract mac))
    ];
    expected = [
      [ ".claude" ]
      true
      true
      true
    ];
  };
}
