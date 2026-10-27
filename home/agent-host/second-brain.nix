# The second-brain wiki (private repo) checked out on the agent host, kept fresh by an hourly user timer, so
# `/brain` (home/cli/claude/commands/brain.md) answers from it. olympus-sdk #562 (decision H7a).
#
# Auth: the clone and the pull use the host's own GitHub SSH key (~/.ssh, the same one every other private
# clone on the host uses); nothing is stored here. The macOS hosts are untouched: they keep the Obsidian
# vault path from home/cli/claude.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost.secondBrain;
  sync = pkgs.writeShellApplication {
    name = "second-brain-sync";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.coreutils
    ];
    text = builtins.readFile ./second-brain-sync.sh;
  };
  env = {
    SECOND_BRAIN_PATH = cfg.path;
    SECOND_BRAIN_REPO = cfg.repo;
  };
in
{
  options.d.agentHost.secondBrain = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Check out the second-brain wiki on this host and pull it hourly.";
    };
    repo = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:nwlnexus/second-brain.git";
    };
    path = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/second-brain";
      description = "Checkout location (SECOND_BRAIN_PATH). Outside both accounts' project trees.";
    };
  };

  config = lib.mkIf (config.d.agentHost.enable && cfg.enable) {
    home.packages = [ sync ];

    # Read by /brain; every shell and the Remote Control launchers source hm-session-vars.sh.
    home.sessionVariables.SECOND_BRAIN_PATH = cfg.path;

    # Clone once when missing. Fail-soft: a host without GitHub access yet just skips it.
    home.activation.secondBrainClone = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") env)} \
        ${sync}/bin/second-brain-sync clone || true
    '';

    systemd.user.services.second-brain-pull = {
      Unit.Description = "Fast-forward the second-brain wiki checkout";
      Service = {
        Type = "oneshot";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") env;
        ExecStart = "${sync}/bin/second-brain-sync pull";
      };
    };
    systemd.user.timers.second-brain-pull = {
      Unit.Description = "Hourly second-brain wiki pull";
      Timer = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
