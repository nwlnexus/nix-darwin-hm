# The Linux agent-host output must not reference macOS-only paths or the
# 1Password desktop app.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  blob = builtins.toJSON (import ./lib/hm-snapshot.nix { inherit lib hm; });
in
{
  testNoHomebrewPaths = {
    expr = lib.hasInfix "/opt/homebrew" blob;
    expected = false;
  };
  testNoApplicationsPaths = {
    expr = lib.hasInfix "/Applications/" blob;
    expected = false;
  };
  testNoMacLibraryPaths = {
    expr = lib.hasInfix "Library/Group Containers" blob;
    expected = false;
  };
  testGitSignsWithSshKeygen = {
    expr = lib.hasSuffix "/bin/ssh-keygen" hm.programs.git.settings.gpg.ssh.program;
    expected = true;
  };
  testCloudflaredFromNix = {
    expr = lib.hasInfix "-cloudflared-" hm.home.file.".ssh/config".text;
    expected = true;
  };
  testNoDarwinReinitScript = {
    expr = hm.home.file."nix-darwin-reinit".enable;
    expected = false;
  };
}
