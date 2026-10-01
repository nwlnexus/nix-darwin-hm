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
  # Removing the native mise leaves its shims pointing at a deleted binary.
  testMiseReshimOnActivation = {
    expr = lib.hasInfix "/bin/mise reshim" (hm.home.activation.miseReshim.data or "");
    expected = true;
  };
  # The host's history DB was migrated by the native atuin 18.23.0; an older
  # binary refuses it ("migration ... was previously applied but is missing").
  testAtuinReadsHostDb = {
    expr = lib.versionAtLeast hm.programs.atuin.package.version "18.23.0";
    expected = true;
  };
  testMisePins = {
    expr = lib.getAttrs [
      "node"
      "pnpm"
      "bun"
      "terraform"
      "terraform-ls"
      "packer"
    ] hm.programs.mise.globalConfig.tools;
    expected = {
      node = "26.10.0";
      pnpm = "12.8.1";
      bun = "1.4.2";
      terraform = "1.16.4";
      terraform-ls = "0.39.0";
      packer = "1.16.1";
    };
  };
  # Sync is on: every host must run the same atuin.
  testAtuinSameOnMacs = {
    expr =
      flake.darwinConfigurations.NWL-MMINI.config.home-manager.users.nwilliams-lucas.programs.atuin.package.version;
    expected = hm.programs.atuin.package.version;
  };
}
