# Work-only hosts: a machine that only ever works on work projects carries none of the personal config. One
# switch, `d.workOnly.enable`, set by a nix-darwin host through `d.workOnly.enable` (system/darwin/work-only.nix)
# or directly in a home-manager host. Off by default, so every other host is unchanged.
#
# What it does here (the gates live next to what they gate; this file sets the defaults and the assertions):
# - op-secrets only from the work 1Password account (d.apps.onepassword.allowedAccounts), with no personal token;
# - no memory-gateway client (asserted off);
# - no personal second-brain: no `/brain` command and no SECOND_BRAIN_PATH default (home/cli/claude), and the
#   agent-host checkout must stay off (asserted);
# - Claude harness: no autoMode source and no telemetry source, both of which come from the private personal
#   input; the agents, hooks, skills and allow rules are generic and stay;
# - git: the work identity is the global identity and there is no personal include (home/cli/git);
# - ssh: no personal GitHub, homelab or tailnet host blocks (home/ssh_config.nix);
# - no ~/projects/personal/.envrc (home/default.nix).
{ config, lib, ... }:
let
  cfg = config.d.workOnly;
  workAccount = "dtlrinc.1password.com";
in
{
  options.d.workOnly = {
    enable = lib.mkEnableOption "work-only mode: evaluate none of the personal secrets, identities, memory or second-brain";

    onepasswordAccount = lib.mkOption {
      type = lib.types.str;
      default = workAccount;
      readOnly = true;
      description = "The only 1Password account op-secrets may use on a work-only host.";
    };
  };

  config = lib.mkIf cfg.enable {
    d.apps.onepassword.allowedAccounts = [ cfg.onepasswordAccount ];

    d.claudeHarness.settings.autoModeFile = lib.mkDefault null;
    d.claudeHarness.telemetry.file = lib.mkDefault null;
    d.claudeHarness.telemetry.account = lib.mkDefault "work";

    assertions = [
      {
        assertion = !config.d.memory.enable;
        message = "d.workOnly: the memory-gateway client (d.memory) is personal; leave it off on a work-only host.";
      }
      {
        assertion = config.d.apps.onepassword.tokenFiles.personal == null;
        message = "d.workOnly: no personal 1Password service-account token file on a work-only host.";
      }
      {
        assertion = !(config.d.agentHost.enable or false) || !config.d.agentHost.secondBrain.enable;
        message = "d.workOnly: set d.agentHost.secondBrain.enable = false; the second-brain wiki is personal.";
      }
      {
        assertion =
          !(config.d.agentHost.enable or false) || config.d.agentHost.defaultAccount != "personal";
        message = "d.workOnly: d.agentHost.defaultAccount must be a work account.";
      }
    ];
  };
}
