# data-hub: Mac Studio M1 Max, a headless personal-infrastructure server (formerly the MACST-02 entry).
#
# Today it serves the llama-server instances (the fallback inference tier behind the A9) and a temporary
# Postgres, and runs the atlas daemon; its future role is CI compute as a native macOS runner (olympus-sdk #661,
# #391). This profile was written from a read-only audit of the host (2026-10-31). It captures the host's state,
# not how it got there: the services themselves (their LaunchDaemons, wrappers, service users, models and
# configs) are still owned by Ansible (olympus-infra data-hub inventory) until atlas replaces it, so they are
# not declared here. Only the Homebrew packages those services run from are declared, so that a later
# `cleanup = "uninstall"` cannot remove them.
#
# Migration from its 25.05 Determinate Nix generation, the audit, and the list of leftovers awaiting an owner
# decision: docs/hosts/data-hub.md. Lines marked `# d.server` belong to the shared headless-server role (olympus-sdk
# H20, nix-darwin-hm branch feat/694-server-role) and move there once that module merges. data-hub is also the tests' bare-Mac fixture (tests/agent-host-darwin.nix,
# tests/memory.nix); the agent-host layer and the memory client stay off here.
{ lib, user, ... }:
{
  config = {
    d.profiles = {
      base = {
        enable = true;
        # The Homebrew formula as a root LaunchDaemon (`sudo brew services start tailscale`), as today. The default
        # ("app") would install the GUI cask, and cleanup would then remove the formula the host runs on.
        tailscale = "formula"; # d.server
        # atlas runs here as a daemon from its own self-updating install in /usr/local/bin (Ansible atlas role);
        # a Homebrew copy would shadow it on PATH.
        atlas = false;
      };
      # CLI dev tooling, as in the running generation; also what a CI runner needs.
      dev.enable = true;
      # Headless: no GUI app profiles.
      gui-small.enable = false; # d.server
      gui-full.enable = false; # d.server
      business.enable = false; # d.server
      gaming.enable = false; # d.server
    };

    # The host's nixbld group (Determinate/upstream installer default on macOS); the old 30000 was never this host's.
    ids.gids.nixbld = 350;
    system.primaryUser = user;

    networking = {
      hostName = "data-hub";
      localHostName = "data-hub";
      computerName = "data-hub";
      # womp 1
      wakeOnLan.enable = true; # d.server
    };

    # Server power settings as found: never sleep, restart after a power failure or a freeze. Disk and display
    # sleep are left as they are (both 10 minutes today).
    power = {
      sleep.computer = "never"; # d.server
      restartAfterPowerFailure = true; # d.server
      restartAfterFreeze = true; # d.server
    };

    # Remote Login (sshd) is how the host is reached; keep it on.
    services.openssh.enable = true; # d.server

    homebrew = {
      # Homebrew packages the live services run from (their LaunchDaemons are Ansible's):
      brews = [
        # ansible-pull (com.olympus.ansible-pull, runs as the `ansible` user from /opt/homebrew/bin)
        "ansible"
        # llama-server instances (com.olympus.llama-server.*); pinned by the Ansible llama-server role
        "llama.cpp"
        # Postgres (com.olympus.postgres, data-services role); temporary until olympus-sdk #444 WS9
        "postgresql@16"
        # ddclient (homebrew.mxcl.ddclient, ddclient role)
        "ddclient"
      ];

      # Do not uninstall undeclared Homebrew packages on this host yet. Its leftovers (retired data tier, GUI and
      # desktop apps from the old profile, VM tooling) are listed in docs/hosts/data-hub.md for the owner to
      # decide; switch back to the fleet default ("uninstall") once that list is settled.
      onActivation.cleanup = lib.mkForce "none";
    };

    home-manager = {
      users.${user} = {
        # Personal infrastructure only: no work secrets, git include, ssh hosts or tree.
        d.personalOnly.enable = true;

        d.apps.onepassword = {
          # Headless: no 1Password desktop app integration (agent socket, op-ssh-sign, autostart).
          gui = false; # d.server
          # None of the op-secrets are on this host today, and a CI host should not hold them: no personal ssh
          # keys, no ~/projects/personal/.env or .op-connect. So no service-account token file is needed either.
          excludeSecrets = [
            "github-personal"
            "gitlab-work"
            "personal-env"
            "op-connect-env"
          ];
        };

        # d.server: no memory-gateway client; none is configured on the host (d.memory.enable stays false).
      };
    };
  };
}
