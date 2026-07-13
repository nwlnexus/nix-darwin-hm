{
  config,
  pkgs,
  lib,
  ...
}:
let
  # One-shot sampler + reaper (see watchdog.sh header for the 2026-07-13 OOM
  # incident that motivated it). launchd re-runs it every 60s; the script
  # itself holds no state in memory, so the watchdog can never become the
  # kind of leak it polices.
  memory-watchdog = pkgs.writeShellApplication {
    name = "memory-watchdog";
    # macOS-native tools only (ps, sysctl, memory_pressure, launchctl,
    # osascript): resolved from the PATH below, not from nixpkgs, because the
    # BSD/Apple variants are exactly what the script is written against.
    runtimeInputs = [ ];
    text = builtins.readFile ./watchdog.sh;
  };
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [ memory-watchdog ];

  launchd.agents.memory-watchdog = {
    enable = true;
    config = {
      ProgramArguments = [ "${memory-watchdog}/bin/memory-watchdog" ];
      StartInterval = 60;
      RunAtLoad = true;
      # One-shot and relaunched every 60s, so even if jetsam kills a run
      # under extreme pressure the next tick still reaps.
      ProcessType = "Standard";
      EnvironmentVariables = {
        PATH = lib.concatStringsSep ":" [
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
        HOME = config.home.homeDirectory;
      };
      StandardOutPath = "${config.home.homeDirectory}/.cache/memory-watchdog/launchd.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.cache/memory-watchdog/launchd.err.log";
    };
  };
}
