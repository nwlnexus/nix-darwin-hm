# mmini-01: Mac mini M4 Pro, a headless server for the cluster (olympus-sdk #694, H20). The retired workstation
# of the same machine was NWL-MMINI. `d.server.enable` (system/darwin/server.nix) is the whole role: no GUI
# profiles, Tailscale as a system daemon, never sleep, Remote Login, passwordless sudo for the primary user.
# Nothing personal: no memory client, no second-brain, no personal tokens.
#
# The native CI runner (system/darwin/server-ci-runner.nix) and the Tart k3s VM (server-linux-vm.nix) are on with
# their defaults; docs/hosts/mmini-01.md lists the one-time steps for both. atlas is not managed here: it is the
# `_atlas` LaunchDaemon from `atlas setup` + `atlas service install --system` (self-updating), as on data-hub.
#
# The flake picks this host by LocalHostName, so the name must be exactly `mmini-01`. First boot, from a
# factory-fresh Mac: docs/hosts/mmini-01.md.
{ user, ... }:
{
  config = {
    d.server = {
      enable = true;
      ciRunner.enable = true;
      linuxVm.enable = true;
    };

    # A fresh upstream Nix install (install.sh) uses gid 350 for nixbld; if darwin-rebuild reports another gid,
    # use the one it names.
    ids.gids.nixbld = 350;
    system.primaryUser = user;
  };
}
