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
    expr = map (s: lib.hasInfix s switch) [
      # Ubuntu socket-activates sshd: /run/sshd may not exist, and `sshd -t` needs it.
      "sudo install -d -m 0755 /run/sshd"
      "if sudo sshd -t; then"
      # No-op when ssh.service is inactive (socket activation picks up the file).
      "sudo systemctl try-reload-or-restart ssh"
    ];
    expected = [
      true
      true
      true
    ];
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
  # A second run must not nest ~/.config/atuin inside atuin.pre-nix.
  testBootstrapAtuinMoveOnce = {
    expr = lib.hasInfix "[ ! -e \"$HOME/.config/atuin.pre-nix\" ]" bootstrap;
    expected = true;
  };
  # `curl | bash` executes while streaming: define everything, then call it.
  testBootstrapRunsAsOneFunction = {
    expr = lib.hasInfix "\nmain() {\n" bootstrap && lib.hasSuffix "\nmain \"$@\"\n" bootstrap;
    expected = true;
  };
  # A .env without the PAT must reach the "re-run later" branch, not die on pipefail.
  testBootstrapPatLookupTolerant = {
    expr = lib.hasInfix "| tr -d \"'\" || true)\"" bootstrap;
    expected = true;
  };
  # The upstream nix-installer doesn't enable flakes; the first switch runs
  # before system-manager writes nix.conf, so the script must enable them.
  testSwitchEnablesFlakes = {
    # NIX_CONFIG also reaches the nix calls system-manager/home-manager make.
    expr = lib.hasInfix "export NIX_CONFIG=\"extra-experimental-features = nix-command flakes\"" switch;
    expected = true;
  };
}
