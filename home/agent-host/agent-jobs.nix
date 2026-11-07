# Scheduled jobs of the agent harness that run scripts from the private olympus-sdk input (epic olympus-sdk#558).
# Both are Linux systemd user timers on the one host that runs them (ai-agent-host); on macOS they are no-ops
# (nothing sets the options there).
#
#   readout     (#573)  weekly: `readout.py --issue` writes the "Agent readout: week of <start>" issue in
#                       nwlnexus/olympus-sdk (idempotent). Needs gh logged in, the tailnet Prometheus, the
#                       olympus-memory plugin's headersHelper and ~/.local/state/agent/denials.jsonl. It reads
#                       its settings from config/claude/telemetry.json next to the script (the default --config
#                       is repo-relative, so the store path works).
#   goalRunner  (#572)  every 15 minutes (counted from the end of the last pass): one pass over `agent:goal`
#                       issues. The script and its guard.py come from the store; the working directory is the
#                       olympus-sdk checkout.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.d.agentHost.jobs;
  inherit (pkgs.stdenv) isDarwin;
  home = config.home.homeDirectory;
  sdk = inputs.olympus-sdk;
  env = [
    "CLAUDE_CONFIG_DIR=${home}/.claude-${config.d.agentHost.defaultAccount}"
    "PATH=${config.d.agentHost.agentPath}"
  ];
  python = "${pkgs.python3}/bin/python3";
  acct = config.d.agentHost.defaultAccount;
  # Same environment as the claude-<acct> launchers (services.nix): the session vars, the account's .env and
  # GH_TOKEN from its GitHub token. A unit gets no login shell, so without this `gh` is logged out.
  withAccountEnv = pkgs.writeShellScript "agent-job-env" ''
    sessionVars=${lib.escapeShellArg "${home}/.nix-profile/etc/profile.d/hm-session-vars.sh"}
    envFile=${lib.escapeShellArg "${config.d.agentHost.accounts.${acct}.root}/.env"}
    if [ -f "$sessionVars" ]; then . "$sessionVars"; fi
    if [ -f "$envFile" ]; then set -a; . "$envFile"; set +a; fi
    if [ -n "''${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"; fi
    export CLAUDE_CONFIG_DIR=${lib.escapeShellArg "${home}/.claude-${acct}"}
    exec "$@"
  '';
in
{
  options.d.agentHost.jobs = {
    readout.enable = lib.mkEnableOption "the weekly agent readout issue (olympus-sdk#573)";
    goalRunner.enable = lib.mkEnableOption "the headless goal runner timer (olympus-sdk#572)";
  };

  config = lib.mkIf (config.d.agentHost.enable && !isDarwin) {
    systemd.user.services.agent-readout = lib.mkIf cfg.readout.enable {
      Unit.Description = "Weekly agent readout issue";
      Service = {
        Type = "oneshot";
        Environment = env;
        ExecStart = "${withAccountEnv} ${python} ${sdk}/scripts/agent-readout/readout.py --issue";
        TimeoutStartSec = "30min";
      };
    };
    systemd.user.timers.agent-readout = lib.mkIf cfg.readout.enable {
      Unit.Description = "Weekly agent readout (Tuesday, after the week closes)";
      Timer = {
        OnCalendar = "Tue *-*-* 14:17:00 UTC";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    systemd.user.services.goal-runner = lib.mkIf cfg.goalRunner.enable {
      Unit = {
        Description = "HW14 headless goal runner (one pass over agent:goal issues)";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        Environment = env;
        WorkingDirectory = "${home}/projects/personal/olympus-sdk";
        ExecStart = "${withAccountEnv} ${python} ${sdk}/scripts/goal-runner/goal_runner.py --timeout 14400";
        # The runner exits 3 for a stuck goal (reported on the issue); only runner errors mark the unit failed.
        SuccessExitStatus = 3;
        # Must exceed --timeout plus the report; KillMode=mixed lets the runner stop its session cleanly.
        TimeoutStartSec = "5h";
        KillMode = "mixed";
        TimeoutStopSec = 150;
      };
    };
    systemd.user.timers.goal-runner = lib.mkIf cfg.goalRunner.enable {
      Unit.Description = "HW14 goal runner every 15 minutes";
      Timer = {
        OnBootSec = "10min";
        OnUnitInactiveSec = "15min";
        RandomizedDelaySec = 60;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
