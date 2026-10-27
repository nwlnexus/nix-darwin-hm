# Headless Ubuntu host for AI agent sessions (Remote Control).
# Discovered by flake.nix: filename = hostname. Outputs:
#   homeConfigurations."nwilliams-lucas@ai-agent-host"  (home)
#   systemConfigs.ai-agent-host                       (os, system-manager)
{
  platform = "x86_64-linux";

  home =
    { config, ... }:
    {
      d.apps.onepassword = {
        gui = false;
        # work-env reads the dtlr Employee vault, which service accounts can't access;
        # ~/projects/work/.env is copied by hand on this host instead. moneta-token
        # reads vault CI, which this host's personal service account cannot see, and
        # it only served the retired mnemosyne writer (olympus-sdk#559).
        excludeSecrets = [
          "work-env"
          "moneta-token"
        ];
        tokenFiles = {
          personal = "${config.home.homeDirectory}/.config/personal/1penv";
          work = "${config.home.homeDirectory}/.config/work/1penv";
        };
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
          work.root = "${config.home.homeDirectory}/projects/work";
        };
      };

      # Picks this host's entry of hostContainment in the autoMode source (home/cli/claude/harness.nix,
      # olympus-sdk#576 layer 2).
      d.claudeHarness.settings.autoModeHost = "ai-agent-host";

      # Memory gateway client (Claude Code MCP server + capture hooks, home/cli/memory; olympus-sdk #559).
      # Keys: 1Password Dev/memory-gateway-keys, fields ai-agent-host-personal and ai-agent-host-work
      # (client ids of the same name, minted with memory-admin). Tailnet only, no public fallback.
      d.memory = {
        enable = true;
        mode = "tailnet";
        fallback = false;
        # The module's default account set (~/.claude plus one per d.agentHost.accounts) is replaced as soon
        # as any accounts.* is defined, so list the accounts explicitly. ~/.claude is not used by any agent
        # session here (owner decision), so it stays unwired.
        accounts = {
          default.enable = false;
          personal = { };
          work = { };
        };
      };
    };

  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
  };
}
