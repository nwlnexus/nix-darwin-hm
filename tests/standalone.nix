# Standalone home-manager output for Linux agent hosts.
{ flake, lib }:
let
  hmc = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  hm = hmc.config;
in
{
  testStandaloneEvaluates = {
    expr = lib.hasSuffix ".drv" hmc.activationPackage.drvPath;
    expected = true;
  };
  testHomeDirectory = {
    expr = hm.home.homeDirectory;
    expected = "/home/nwilliams-lucas";
  };
  testGenericLinux = {
    expr = hm.targets.genericLinux.enable;
    expected = true;
  };
  # d.shell aliases from home/cli/git/ui.nix reach home.shellAliases.
  testShellAliasesApplied = {
    expr = hm.home.shellAliases.gi or null;
    expected = "lazygit";
  };
  testBuiltinAliases = {
    expr = hm.home.shellAliases."..";
    expected = "cd ..";
  };
  testShellPrograms = {
    expr = [
      hm.programs.zsh.enable
      hm.programs.direnv.enable
      hm.programs.direnv.nix-direnv.enable
      hm.programs.mise.enableZshIntegration
    ];
    expected = [
      true
      true
      true
      true
    ];
  };
  # The two HM-managed tree .envrc files are trusted; nothing broader.
  testDirenvWhitelist = {
    expr = hm.programs.direnv.config.whitelist.exact;
    expected = [
      "/home/nwilliams-lucas/projects/personal/.envrc"
      "/home/nwilliams-lucas/projects/work/.envrc"
    ];
  };
  # ~/.zshenv used to source ~/.cargo/env; HM now owns .zshenv.
  testCargoOnPath = {
    expr = builtins.elem "/home/nwilliams-lucas/.cargo/bin" hm.home.sessionPath;
    expected = true;
  };
  testStarshipVariable = {
    expr = hm.home.sessionVariables.STARSHIP_LOG;
    expected = "error";
  };
}
