# data-hub: Mac Studio M1 Max, a headless server (olympus-sdk #697, H20): `d.server.enable` is the role (no GUI
# profiles, never sleep, Remote Login, passwordless sudo for the primary user, no op-secrets, nothing personal).
#
# Since olympus-sdk #701 it is compute like the Mac minis: the native CI runner and the Tart k3s VM (data-hub-vm)
# are on, as on mmini-01 (one-time steps: docs/hosts/data-hub.md). The VM is larger than the minis' (8 vCPU, 32 GiB):
# the 27B llama-server instance and Postgres it used to run were retired in #701. It still serves two small
# llama-server instances (the coder-light fallback behind the A9, and an embed fallback) and runs atlas.
# Those services (their LaunchDaemons, wrappers, models and configs) stay owned by Ansible (olympus-infra data-hub
# inventory) until atlas replaces it, so they are not declared here. Only the Homebrew packages they run from are
# declared, so a switch can never remove them. The same goes for tailscaled: Ansible's tailscale role runs it (a
# root brew service and a watchdog), so the role's own daemon is off here.
#
# Audit (2026-10-31) and the migration from its Determinate Nix / nix-darwin 25.05 generation: docs/hosts/data-hub.md.
# data-hub is also a test fixture (tests/agent-host-darwin.nix, tests/memory.nix), which turn the server role off.
{ lib, user, ... }:
{
  config = {
    d.server = {
      enable = true;
      tailscaleDaemon = false;
      ciRunner.enable = true;
      linuxVm = {
        enable = true;
        cpus = 8;
        memoryGiB = 32;
      };
    };

    d.profiles = {
      base = {
        enable = true;
        # atlas runs here as a daemon from its own self-updating install in /usr/local/bin; a Homebrew copy would
        # shadow it on PATH.
        atlas = false;
      };
      # CLI dev tooling; also what a CI runner needs.
      dev.enable = true;
    };

    # The host's nixbld group (the installer default on macOS).
    ids.gids.nixbld = 350;
    system.primaryUser = user;

    networking = {
      hostName = "data-hub";
      localHostName = "data-hub";
      computerName = "data-hub";
    };

    homebrew = {
      # Homebrew packages the live services run from (their LaunchDaemons are Ansible's):
      brews = [
        # ansible-pull (com.olympus.ansible-pull, runs as the `ansible` user from /opt/homebrew/bin)
        "ansible"
        # llama-server instances (com.olympus.llama-server.*); pinned by the Ansible llama-server role
        "llama.cpp"
        # ddclient (homebrew.mxcl.ddclient, ddclient role)
        "ddclient"
      ];

      # Never uninstall undeclared Homebrew packages here: Ansible installs some of what the services need, and
      # a switch must not remove them. The old leftovers were removed by hand (olympus-sdk #697). Revisit when
      # atlas replaces Ansible.
      onActivation.cleanup = lib.mkForce "none";
    };
  };
}
