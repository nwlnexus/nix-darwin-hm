# dtlr-ai-agent-host: a work-only Mac Studio agent host (olympus-sdk #691). Runs like ai-agent-host
# (headless-capable, Remote Control, tmux, CLI) for ONE account, `work`, rooted at ~/projects/work.
#
# Work-only (d.workOnly, system/darwin/work-only.nix + home/work-only.nix): no personal 1Password account or
# token, no personal secrets, no memory-gateway client, no second-brain, no personal git identity or ssh hosts,
# no autoMode/telemetry from the private personal input, and that input is not referenced at all, so this host
# evaluates without access to it. tests/work-only.nix asserts all of it.
#
# Bootstrap and owner steps: docs/hosts/dtlr-ai-agent-host.md.
{ user, ... }:
{
  config = {
    d.profiles = {
      base = {
        enable = true;
        # Tailscale as on the other servers: the Homebrew formula as a root LaunchDaemon
        # (`sudo brew services start tailscale`), never the GUI app cask.
        tailscale = "formula";
      };
      dev.enable = true;
      gui-small.enable = false;
      # CLI-only. Flip to true only if the Desktop app is used here (also brings the 1Password app).
      gui-full.enable = false;
      business.enable = false;
      gaming.enable = false;
    };

    d.workOnly.enable = true;

    # Fresh Determinate Nix installs on macOS use gid 350 for nixbld; if darwin-rebuild reports another gid,
    # use the one it names.
    ids.gids.nixbld = 350;
    system.primaryUser = user;

    # Server-like power settings: never sleep (the display may), restart after a power failure or a freeze,
    # wake on network access. Equivalent to `pmset -a sleep 0 disksleep 0 autorestart 1 womp 1`.
    power = {
      sleep = {
        computer = "never";
        harddisk = "never";
      };
      restartAfterPowerFailure = true;
      restartAfterFreeze = true;
    };
    networking.wakeOnLan.enable = true;

    home-manager = {
      users.${user} =
        { config, ... }:
        {
          d.apps.onepassword = {
            # No 1Password desktop app (gui-full is off): op-secrets uses the work service-account token.
            gui = false;
            tokenFiles.work = "${config.home.homeDirectory}/.config/work/1penv";
          };

          d.agentHost = {
            enable = true;
            defaultAccount = "work";
            accounts.work = {
              root = "${config.home.homeDirectory}/projects/work";
              remoteControl = {
                claude = true;
                # Set false if Codex is not used on this host.
                codex = true;
              };
            };
            secondBrain.enable = false;
          };

          d.memory.enable = false;
        };
    };
  };
}
