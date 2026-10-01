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
  testGitDefaultSigningKey = {
    expr = hm.programs.git.signing.key;
    expected = "~/.ssh/id_ed25519";
  };
  testNoSshAuthSock = {
    expr = hm.home.sessionVariables ? SSH_AUTH_SOCK;
    expected = false;
  };
  testNo1PasswordGuiAutostart = {
    expr = hm.systemd.user.services ? _1password-gui;
    expected = false;
  };
  # op-secrets drops the module-level token whenever a secret sets `account`
  # (all of ours do), so every secret needs its own token command.
  testEverySecretHasToken = {
    expr = lib.all (s: s.serviceAccountTokenCommand != null) (lib.attrValues hm.op-secrets.secrets);
    expected = true;
  };
  # work-env reads the dtlr built-in Employee vault, which 1Password service
  # accounts can't access; agent hosts keep a hand-copied .env instead.
  testWorkEnvSkippedOnAgentHost = {
    expr = hm.op-secrets.secrets ? work-env;
    expected = false;
  };
  testOtherSecretsKept = {
    expr = lib.attrNames hm.op-secrets.secrets;
    expected = [
      "github-personal"
      "gitlab-work"
      "moneta-cf-access-client-id"
      "moneta-cf-access-client-secret"
      "moneta-token"
      "op-connect-env"
      "personal-env"
    ];
  };
  testPersonalKeyUsesPersonalToken = {
    expr = hm.op-secrets.secrets.github-personal.serviceAccountTokenCommand;
    expected = "cat /home/nwilliams-lucas/.config/personal/1penv";
  };
}
