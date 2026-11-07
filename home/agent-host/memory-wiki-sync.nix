# Nightly proposal of the personal Claude Code auto-memory into the second-brain wiki inbox (olympus-sdk #669,
# ownership rule H21). The job itself (`memory-wiki-sync`) ships in the olympus-memory plugin; plugins cannot declare
# timers, so nix only declares the schedule and resolves the script from the plugin's installed_plugins.json (a
# plugin update is picked up without a nix change). It writes status: new notes into $SECOND_BRAIN_PATH/raw/_inbox,
# never deletes or edits anything, and reads only the listed personal accounts' memory (#675). Off where the
# second-brain checkout is off (a work-only host) and refused for any account named *work*.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost.memoryWikiSync;
  inherit (pkgs.stdenv) isDarwin;
  run = pkgs.writeShellApplication {
    name = "memory-wiki-sync-run";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.findutils
    ];
    text = builtins.readFile ./memory-wiki-sync-run.sh;
  };
  env = {
    MEMORY_WIKI_SYNC_ACCOUNTS = lib.concatStringsSep " " cfg.accounts;
    SECOND_BRAIN_PATH = config.d.agentHost.secondBrain.path;
  };
in
{
  options.d.agentHost.memoryWikiSync = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.d.agentHost.secondBrain.enable;
      defaultText = lib.literalExpression "config.d.agentHost.secondBrain.enable";
      description = "Run the nightly auto-memory to second-brain raw/_inbox proposal job. Set false on a work-only host.";
    };
    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "personal" ];
      description = "Accounts whose ~/.claude-<name>/projects memory is proposed. Personal accounts only (never a work account).";
    };
    hour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 3;
      description = "Hour of day (local) of the nightly run; the minute is fixed at 30 (systemd adds a random delay).";
    };
  };

  config = lib.mkIf (config.d.agentHost.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.all (a: !(lib.hasInfix "work" a)) cfg.accounts;
        message = "d.agentHost.memoryWikiSync.accounts must not include a work account (personal/work memory boundary, #675)";
      }
      {
        assertion = config.d.agentHost.secondBrain.enable;
        message = "d.agentHost.memoryWikiSync needs d.agentHost.secondBrain.enable (it writes into the wiki checkout)";
      }
    ];

    home.packages = [ run ];

    launchd.agents.memory-wiki-sync = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProgramArguments = [ "${run}/bin/memory-wiki-sync-run" ];
        EnvironmentVariables = env;
        StartCalendarInterval = [
          {
            Hour = cfg.hour;
            Minute = 30;
          }
        ];
        StandardInPath = "/dev/null";
        StandardOutPath = "${config.d.agentHost.logDir}/memory-wiki-sync.log";
        StandardErrorPath = "${config.d.agentHost.logDir}/memory-wiki-sync.log";
      };
    };

    systemd.user.services.memory-wiki-sync = lib.mkIf (!isDarwin) {
      Unit.Description = "Propose personal auto-memory into the second-brain wiki inbox";
      Service = {
        Type = "oneshot";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") env;
        ExecStart = "${run}/bin/memory-wiki-sync-run";
      };
    };
    systemd.user.timers.memory-wiki-sync = lib.mkIf (!isDarwin) {
      Unit.Description = "Nightly auto-memory to wiki-inbox proposals";
      Timer = {
        OnCalendar = "*-*-* ${lib.fixedWidthString 2 "0" (toString cfg.hour)}:30:00";
        RandomizedDelaySec = "15m";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
