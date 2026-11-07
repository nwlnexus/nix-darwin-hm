# Headless Ubuntu host for AI agent sessions (Remote Control).
# Discovered by flake.nix: filename = hostname. Outputs:
#   homeConfigurations."nwilliams-lucas@ai-agent-host"  (home)
#   systemConfigs.ai-agent-host                       (os, system-manager)
{
  platform = "x86_64-linux";

  home =
    { config, ... }:
    {
      # Personal-only (olympus-sdk#693, home/personal-only.nix): no work account, tree, secret or git/ssh
      # config here. Work agents run on dtlr-ai-agent-host.
      d.personalOnly.enable = true;

      d.apps.onepassword = {
        gui = false;
        tokenFiles.personal = "${config.home.homeDirectory}/.config/personal/1penv";
      };

      # Only what nixpkgs lacks or lags badly on; Nix stays the default.
      d.linuxbrew = {
        enable = true;
        taps = [ "nwlnexus/olympus" ];
        brews = [
          "nwlnexus/olympus/atlas"
          "neonctl"
          "flyctl"
          "argocd"
        ];
      };

      d.agentHost = {
        enable = true;
        accounts = {
          personal.root = "${config.home.homeDirectory}/projects/personal";
        };
      };

      # Picks this host's entry of hostContainment in the autoMode source (home/cli/claude/harness.nix,
      # olympus-sdk#576 layer 2).
      d.claudeHarness.settings.autoModeHost = "ai-agent-host";

      # Memory comes from the olympus-memory plugin (olympus-sdk#753): ~/.claude-personal declares the private
      # olympus-private marketplace and enables olympus-memory; its /olympus-memory:setup writes ~/.config/memory
      # (key field ai-agent-host-personal of Dev/memory-gateway-keys). The nix memory module is off and cleanup
      # removes its hook entries and `memory` MCP entry from the files it recorded; key files stay. ~/.claude stays
      # unwired (owner decision H17).
      d.claudeHarness.plugins.private.enable = true;
      d.memory = {
        enable = false;
        cleanup = true;
      };
    };

  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
  };
}
