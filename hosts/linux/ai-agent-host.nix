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

      # Memory gateway client (Claude Code MCP server + capture hooks, home/cli/memory; olympus-sdk #559).
      # Key: 1Password Dev/memory-gateway-keys, field ai-agent-host-personal (client id of the same name,
      # minted with memory-admin). Tailnet only, no public fallback.
      d.memory = {
        enable = true;
        mode = "tailnet";
        fallback = false;
        # The module's default account set (~/.claude plus one per d.agentHost.accounts) is replaced as soon
        # as any accounts.* is defined, so list the accounts explicitly. ~/.claude is not used by any agent
        # session here (owner decision), so it stays unwired.
        #
        # There is no work account on this host (olympus-sdk#693; work runs on dtlr-ai-agent-host). The
        # personal account uses the module's default routes, which stay fail-closed:
        # ~/projects/personal -> gateway, ~/projects/work -> none (olympus-sdk #675).
        accounts = {
          default.enable = false;
          personal = { };
        };
      };
    };

  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
  };
}
