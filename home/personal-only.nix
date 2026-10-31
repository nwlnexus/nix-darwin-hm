# Personal-only hosts: a machine that only ever works on personal projects carries none of the work config.
# One switch, `d.personalOnly.enable`, the mirror image of `d.workOnly` (home/work-only.nix). Off by default, so
# every other host is unchanged.
#
# What it does here (the gates live next to what they gate; this file sets the defaults and the assertions):
# - op-secrets only from the personal 1Password account (d.apps.onepassword.allowedAccounts), so the `work-env`
#   secret is neither evaluated nor fetched, and no work token file is needed;
# - no ~/projects/work/.envrc, no direnv whitelist entry for it and no mise trust for the tree (home/default.nix,
#   home/linux-shell.nix);
# - git: no work include (`gitdir:projects/work/` and the work remote patterns; home/cli/git);
# - ssh: no work GitHub/GitLab alias, no dtlr switch or bastion blocks (home/ssh_config.nix);
# - memory: nothing changes. The default routes still map ~/projects/work to `none` (fail closed); no work
#   route is added here.
{ config, lib, ... }:
let
  cfg = config.d.personalOnly;
  personalAccount = "my.1password.com";
  underWork = root: lib.hasInfix "/projects/work/" "${root}/";
in
{
  options.d.personalOnly = {
    enable = lib.mkEnableOption "personal-only mode: evaluate none of the work secrets, identities, accounts or trees";

    onepasswordAccount = lib.mkOption {
      type = lib.types.str;
      default = personalAccount;
      readOnly = true;
      description = "The only 1Password account op-secrets may use on a personal-only host.";
    };
  };

  config = lib.mkIf cfg.enable {
    d.apps.onepassword.allowedAccounts = [ cfg.onepasswordAccount ];

    assertions = [
      {
        assertion = !config.d.workOnly.enable;
        message = "d.personalOnly: mutually exclusive with d.workOnly.";
      }
      {
        assertion = config.d.apps.onepassword.tokenFiles.work == null;
        message = "d.personalOnly: no work 1Password service-account token file on a personal-only host.";
      }
      {
        assertion =
          !(config.d.agentHost.enable or false)
          || !lib.any (a: underWork a.root) (lib.attrValues config.d.agentHost.accounts);
        message = "d.personalOnly: no d.agentHost account may be rooted under ~/projects/work.";
      }
    ];
  };
}
