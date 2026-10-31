# mmini-01: Mac mini M4 Pro, a headless server for the cluster (olympus-sdk #694, H20). The retired workstation
# of the same machine was NWL-MMINI. `d.server.enable` (system/darwin/server.nix) is the whole role: no GUI
# profiles, Tailscale as a system daemon, never sleep, Remote Login, passwordless sudo for the primary user.
# Nothing personal: no memory client, no second-brain, no personal tokens.
#
# The CI runner, the Tart VM and atlas come in later PRs (olympus-sdk #694); they extend this file.
#
# The flake picks this host by LocalHostName, so the name must be exactly `mmini-01`. First boot, from a
# factory-fresh Mac: docs/hosts/mmini-01.md.
{ user, ... }:
{
  config = {
    d.server.enable = true;

    # A fresh upstream Nix install (install.sh) uses gid 350 for nixbld; if darwin-rebuild reports another gid,
    # use the one it names.
    ids.gids.nixbld = 350;
    system.primaryUser = user;
  };
}
