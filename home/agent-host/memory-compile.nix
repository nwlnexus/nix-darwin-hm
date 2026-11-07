# Nightly knowledge compile (olympus-sdk #455, design 2026-10-21 contract section 16): memory-gateway facts and the
# raw/_inbox proposals (the #669 auto-memory sync among them) become second-brain wiki articles. Drafting and the
# claim-verifier run as the personal Claude account; the result is a PR labelled compile + automerge that merges
# once the wiki's CI lint passes (no manual gate). The code is second-brain's scripts/compile/compile.mjs; nix only
# declares the schedule and the clone it works in. Off where the second-brain checkout is off (a work-only host).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost.memoryCompile;
  home = config.home.homeDirectory;
  inherit (pkgs.stdenv) isDarwin;
  run = pkgs.writeShellApplication {
    name = "memory-compile-run";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.nodejs_22
      pkgs.gh
      pkgs.coreutils
    ];
    text = builtins.readFile ./memory-compile-run.sh;
  };
  env = {
    MEMORY_COMPILE_DIR = cfg.dir;
    SECOND_BRAIN_REPO = config.d.agentHost.secondBrain.repo;
    MEMORY_ENV_FILE = "${home}/.config/memory/env-${cfg.account}";
    CLAUDE_CONFIG_DIR = "${home}/.claude-${cfg.account}";
    # The account's op-secrets env file (as the claude-<acct> launchers use, services.nix): GITHUB_PERSONAL_ACCESS_TOKEN
    # for `gh pr create`. The unit has no login shell, so nothing else provides it.
    MEMORY_COMPILE_SECRETS_FILE = "${config.d.agentHost.accounts.${cfg.account}.root}/.env";
  };
in
{
  options.d.agentHost.memoryCompile = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.d.agentHost.secondBrain.enable;
      defaultText = lib.literalExpression "config.d.agentHost.secondBrain.enable";
      description = "Run the nightly memory-facts-to-wiki compile. Set false on a work-only host.";
    };
    account = lib.mkOption {
      type = lib.types.str;
      default = "personal";
      description = "Claude account (and olympus-memory env file) the compile runs as. Never a work account.";
    };
    dir = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.local/state/memory-compile/second-brain";
      description = "The compile's own second-brain clone (not the /brain checkout).";
    };
    hour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 4;
      description = "Hour of day (local) of the nightly run, after the 03:30 auto-memory sync; minute fixed at 45.";
    };
  };

  config = lib.mkIf (config.d.agentHost.enable && cfg.enable) {
    assertions = [
      {
        assertion = !(lib.hasInfix "work" cfg.account);
        message = "d.agentHost.memoryCompile.account must not be a work account (personal/work memory boundary, #675)";
      }
    ];

    home.packages = [ run ];

    launchd.agents.memory-compile = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProgramArguments = [ "${run}/bin/memory-compile-run" ];
        EnvironmentVariables = env;
        StartCalendarInterval = [
          {
            Hour = cfg.hour;
            Minute = 45;
          }
        ];
        StandardInPath = "/dev/null";
        StandardOutPath = "${config.d.agentHost.logDir}/memory-compile.log";
        StandardErrorPath = "${config.d.agentHost.logDir}/memory-compile.log";
      };
    };

    systemd.user.services.memory-compile = lib.mkIf (!isDarwin) {
      Unit.Description = "Compile memory facts and inbox proposals into second-brain wiki articles";
      Service = {
        Type = "oneshot";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") env;
        ExecCondition = "${pkgs.coreutils}/bin/test -f ${home}/.claude-${cfg.account}/.credentials.json";
        ExecStart = "${run}/bin/memory-compile-run";
        TimeoutStartSec = "2h";
      };
    };
    systemd.user.timers.memory-compile = lib.mkIf (!isDarwin) {
      Unit.Description = "Nightly memory compile into the wiki";
      Timer = {
        OnCalendar = "*-*-* ${lib.fixedWidthString 2 "0" (toString cfg.hour)}:45:00";
        RandomizedDelaySec = "10m";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
