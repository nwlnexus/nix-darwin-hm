# Declarative Linuxbrew on standalone (non-NixOS) hosts.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  prefix = "/home/linuxbrew/.linuxbrew";
  bundle = hm.home.activation.linuxbrewBundle.data or "";
  str = v: lib.concatStringsSep " " (map toString (lib.toList v));
  bootstrap = builtins.readFile ../scripts/bootstrap-agent-host.sh;
in
{
  testBrewfile = {
    expr = hm.home.file.".Brewfile".text;
    expected = ''
      tap "nwlnexus/olympus", trusted: true
      brew "nwlnexus/olympus/atlas"
      brew "neonctl"
      brew "flyctl"
      brew "gemini-cli"
      brew "argocd"
    '';
  };
  # Install-only: nothing is upgraded or removed by a switch.
  testBundleInstallOnly = {
    expr = [
      (lib.hasInfix "bundle install" bundle)
      (lib.hasInfix "--no-upgrade" bundle)
      (lib.hasInfix "--cleanup" bundle)
    ];
    expected = [
      true
      true
      false
    ];
  };
  # A brew/network failure must not abort the rest of activation.
  testBundleFailureOnlyWarns = {
    expr = lib.hasInfix "warnEcho \"linuxbrew: brew bundle failed" bundle;
    expected = true;
  };
  # Brew's own deps (e.g. node for gemini-cli) must never shadow Nix/mise.
  testBrewLastOnShellPath = {
    expr = lib.take 2 (lib.reverseList hm.home.sessionPath);
    expected = [
      "${prefix}/sbin"
      "${prefix}/bin"
    ];
  };
  testBrewLastOnAgentPath = {
    expr = lib.hasSuffix ":${prefix}/bin:${prefix}/sbin" (
      str hm.systemd.user.services.claude-rc-work.Service.Environment
    );
    expected = true;
  };
  testBootstrapInstallsBrewOnce = {
    expr = lib.hasInfix "if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]" bootstrap;
    expected = true;
  };
}
