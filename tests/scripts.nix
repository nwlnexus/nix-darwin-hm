# Static guarantees about the Linux switch/bootstrap scripts.
{ flake, lib }:
let
  switch = builtins.readFile ../scripts/linux-switch.sh;
  bootstrap = builtins.readFile ../scripts/bootstrap-agent-host.sh;
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
in
{
  # Never reload sshd on a config it rejects (would risk losing ssh access).
  testSwitchValidatesSshd = {
    expr = lib.hasInfix "if sudo sshd -t; then" switch && lib.hasInfix "systemctl reload ssh" switch;
    expected = true;
  };
  # Every mutating bootstrap step is behind a check, so re-runs are no-ops.
  testBootstrapIdempotentGuards = {
    expr = map (s: lib.hasInfix s bootstrap) [
      "if [ -d /nix ]"
      "if [ -s \"$f\" ]"
      "if [ -d \"$HOME/.atuin/bin\" ]"
      "if [ ! -d \"$REPO/.git\" ]"
      "if [ ! -s /etc/nix/github-token.conf ]"
    ];
    expected = [
      true
      true
      true
      true
      true
    ];
  };
  testBootstrapHasDryRun = {
    expr = lib.hasInfix "--dry-run" bootstrap;
    expected = true;
  };
  testSwitchAlias = {
    expr = lib.hasSuffix "/projects/personal/nix-darwin-hm/scripts/linux-switch.sh" hm.home.shellAliases.switch;
    expected = true;
  };
  # Run as `curl … | bash`, stdin is the script itself: prompts must read the tty.
  testBootstrapPromptsFromTty = {
    expr = lib.hasInfix "read -rsp \"  $acct service-account token: \" tok </dev/tty" bootstrap;
    expected = true;
  };
}
