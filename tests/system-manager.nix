# system-manager OS layer for Linux agent hosts.
{ flake, lib }:
let
  smc = flake.systemConfigs.ai-agent-host;
  sm = smc.config;
in
{
  testSystemConfigEvaluates = {
    expr = lib.hasSuffix ".drv" smc.drvPath;
    expected = true;
  };
  # The Nix installer creates /etc/nix/nix.conf; take it over explicitly.
  testNixConfReplacesInstallerFile = {
    expr = sm.environment.etc."nix/nix.conf".replaceExisting;
    expected = true;
  };
  # Sorted (order is irrelevant to Nix) but not deduplicated, so a repeated
  # entry still fails.
  testTrustedUsers = {
    expr = lib.sort lib.lessThan sm.nix.settings.trusted-users;
    expected = [
      "nwilliams-lucas"
      "root"
    ];
  };
  # Replacing the installer's nix.conf must keep its build-users-group.
  testBuildUsersGroup = {
    expr = sm.nix.settings.build-users-group;
    expected = "nixbld";
  };
  testGithubTokenInclude = {
    expr = lib.hasInfix "!include /etc/nix/github-token.conf" sm.nix.extraOptions;
    expected = true;
  };
  testLinger = {
    expr = builtins.elem "f /var/lib/systemd/linger/nwilliams-lucas 0644 root root -" sm.systemd.tmpfiles.rules;
    expected = true;
  };
  testSshdDropIn = {
    expr = sm.environment.etc."ssh/sshd_config.d/05-nix-hardening.conf".text;
    expected = ''
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      PubkeyAuthentication yes
    '';
  };
  testWeeklyGc = {
    expr = lib.toList sm.systemd.services.nix-gc.startAt;
    expected = [ "Sun *-*-* 03:00:00" ];
  };
  testPinnedCliPackages = {
    expr = builtins.attrNames flake.packages.x86_64-linux;
    expected = [
      "home-manager"
      "system-manager"
    ];
  };
}
