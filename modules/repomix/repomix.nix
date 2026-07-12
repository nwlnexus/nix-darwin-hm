{
  config,
  pkgs,
  lib,
  ...
}:
let
  repoRoot = "${config.home.homeDirectory}/projects/personal/nix-darwin-hm";
  repomix-pack = pkgs.writeShellApplication {
    name = "repomix-pack";
    runtimeInputs = [
      pkgs.bun
      pkgs.git
      pkgs.gh
      pkgs._1password-cli
    ];
    text = ''exec bun run "${repoRoot}/scripts/repomix-pack/src/index.ts" "$@"'';
  };
in
{
  home.packages = [ repomix-pack ];

  launchd.agents.repomix-pack = {
    enable = true;
    config = {
      ProgramArguments = [
        "${repomix-pack}/bin/repomix-pack"
        "--group"
        "all"
      ];
      StartCalendarInterval = [
        {
          Hour = 9;
          Minute = 0;
        }
      ];
      RunAtLoad = false;
      StandardOutPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.err.log";
    };
  };
}
