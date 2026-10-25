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
        # Reads the dtlr Employee vault, which service accounts can't access;
        # ~/projects/work/.env is copied by hand on this host instead.
        excludeSecrets = [ "work-env" ];
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

      # Memory gateway client (Claude Code MCP server + capture hooks, home/cli/memory). NOT enabled yet:
      # first create the 1Password items and mint the keys (AGENTS.md, "Memory gateway client"). Then:
      #
      # d.memory = {
      #   enable = true;
      #   # mode = "tailnet";   # default; "public" for a machine off the tailnet
      #   fallback = true;      # hooks fall back to the public URL when the tailnet is down (needs the Access token)
      #   # Accounts default to ~/.claude plus one per d.agentHost.accounts (~/.claude-personal, ~/.claude-work).
      #   # Drop ~/.claude, which no agent session uses here, so it needs no key:
      #   # accounts.default.enable = false;
      # };
    };

  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
  };
}
