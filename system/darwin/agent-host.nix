# d.agentHost (home/agent-host) for the Macs: per-account Claude Code / Codex dirs, Remote Control as boot-time
# LaunchDaemons that run as the user (so they start with nobody logged in), the `agents` helper and the
# second-brain checkout. Off unless a host sets d.agentHost.enable in its home-manager user (olympus-sdk #690),
# so importing it changes nothing on the existing Macs.
{
  config,
  lib,
  user,
  ...
}:
let
  hm = config.home-manager.users.${user}.d.agentHost;
in
{
  config = lib.mkMerge [
    { d.hm = [ ../../home/agent-host ]; }

    (lib.mkIf hm.enable {
      launchd.daemons = lib.mapAttrs (_: spec: { serviceConfig = spec; }) hm.darwinDaemons;

      # Daemons load at boot, before any user activation, so the log dir must exist already. Power through
      # pmset: nix-darwin's power.* uses `systemsetup`, which is silent without Full Disk Access (server.nix).
      # displaysleep is left alone.
      system.activationScripts.postActivation.text = ''
        echo "configuring agent-host log dir and power (pmset)..." >&2
        /usr/bin/install -d -o ${user} -g staff -m 0755 ${lib.escapeShellArg hm.logDir}
        /usr/bin/pmset -a sleep 0 disksleep 0 autorestart 1 womp 1
      '';
    })
  ];
}
