# Server Macs, home-manager side (olympus-sdk #694, H20). Set by `d.server.enable` in a nix-darwin host
# (system/darwin/server.nix), which holds the system half and the profile assertions. Off by default, so every
# other host is unchanged.
#
# - no memory-gateway client, no second-brain and no agent-host layer (its Remote Control services are
#   LaunchAgents, which need a logged-in GUI session); all asserted off;
# - no 1Password desktop-app integration (`d.apps.onepassword.gui` defaults to false);
# - no autoMode or telemetry source: both come from the private `olympus-sdk` input, which a server does not
#   fetch, so a factory-fresh Mac with no ssh key can build.
{ config, lib, ... }:
let
  cfg = config.d.server;
in
{
  options.d.server.enable = lib.mkEnableOption "server mode: headless, with none of the personal memory, second-brain or GUI integration";

  config = lib.mkIf cfg.enable {
    d.apps.onepassword.gui = lib.mkDefault false;
    # No op-secrets at all: a server holds no personal ssh keys or .env files, so it needs no 1Password token.
    # What a server does need (runner App files, the VM's ansible key) is installed root-only by hand
    # (docs/hosts/mmini-01.md).
    d.apps.onepassword.allowedAccounts = lib.mkDefault [ ];

    d.claudeHarness.settings.autoModeFile = lib.mkDefault null;
    d.claudeHarness.telemetry.file = lib.mkDefault null;

    assertions = [
      {
        assertion = !config.d.memory.enable;
        message = "d.server: the memory-gateway client (d.memory) is personal; leave it off on a server.";
      }
      {
        assertion = !(config.d.agentHost.enable or false);
        message = "d.server: the agent-host layer runs as LaunchAgents, which need a GUI session; a server runs only LaunchDaemons.";
      }
      {
        assertion = !(config.d.agentHost.enable or false) || !config.d.agentHost.secondBrain.enable;
        message = "d.server: no second-brain wiki on a server.";
      }
    ];
  };
}
