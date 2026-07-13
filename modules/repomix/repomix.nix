{
  config,
  pkgs,
  lib,
  ...
}:
let
  repoRoot = "${config.home.homeDirectory}/projects/personal/nix-darwin-hm";

  # Neither `repomix` nor `gitnexus` resolves under launchd.
  #
  # Both were mise globals (npm:repomix, npm:gitnexus), and a mise global's only
  # PATH entry is the shims dir -- which the INTERACTIVE shell profile adds. A
  # launchd agent sources no profile: its PATH is the bare
  # /usr/bin:/bin:/usr/sbin:/sbin, where neither binary exists. Verified:
  #   env -i PATH=/usr/bin:/bin sh -c 'command -v gitnexus repomix'  -> neither
  # So every scheduled sweep died on the first `repomix` spawn
  # ("bun: command not found: repomix"), which is why
  # ~/.cache/repomix-pipeline/launchd.*.log never existed: the agent has never
  # completed a single run since it was installed.
  #
  # repomix is fixed HERMETICALLY, from nixpkgs -- not via the shim. A mise shim
  # refuses to run when the CWD carries an untrusted mise config, and repomix is
  # invoked with cwd = the repo checkout: 2 of the 11 (dtlr/drop-app,
  # nwlnexus/moneta) ship a mise.toml, and the shim dies there with "Config files
  # in ... are not trusted" (verified). Auto-trusting arbitrary repo configs from
  # an unattended sweep is not a trade worth making. The nixpkgs build has no cwd
  # semantics at all, needs no mise, and works under `env -i` (verified against
  # the real repomix.config.json inside the drop-app checkout).
  #
  # gitnexus is NOT in nixpkgs, so it stays a mise global and keeps needing the
  # shims dir. That is safe: the graph stage invokes it from a NEUTRAL cwd (see
  # GraphOpts.neutralCwd in graph.ts), precisely to dodge the trust rule above --
  # and graph.ts targets the shim by ABSOLUTE path anyway (defaultGitnexusBin),
  # so this PATH entry is belt-and-braces.
  #
  # The SHIMS dir, never `installs/npm-*/latest/bin/*`: those are
  # `#!/usr/bin/env node` scripts, and `node` is ITSELF a mise global that is
  # equally absent from a bare PATH (`env: node: No such file or directory`).
  # Each shim is the mise binary itself, which resolves its own node.
  miseShims = "${config.home.homeDirectory}/.local/share/mise/shims";

  repomix-pack = pkgs.writeShellApplication {
    name = "repomix-pack";
    runtimeInputs = [
      pkgs.bun
      pkgs.git
      pkgs.gh
      pkgs._1password-cli
      pkgs.repomix
    ];
    # APPENDED, never prepended: the shims dir also carries `bun` and `repomix`,
    # and the nix ones (prepended by writeShellApplication) must keep winning.
    # Only `gitnexus`, which nix does not provide, is meant to resolve here.
    text = ''
      export PATH="$PATH:${miseShims}"
      exec bun run "${repoRoot}/scripts/repomix-pack/src/index.ts" "$@"
    '';
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
      # launchd hands a job an almost-empty environment: no profile is sourced,
      # so PATH is whatever is set here (or the bare system default). Belt and
      # braces with the wrapper's own PATH above -- this one also covers `mise`
      # itself, and anything the tools shell out to.
      EnvironmentVariables = {
        PATH = lib.concatStringsSep ":" [
          miseShims
          "/etc/profiles/per-user/${config.home.username}/bin"
          "/run/current-system/sw/bin"
          "/nix/var/nix/profiles/default/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
        HOME = config.home.homeDirectory;
      };
      RunAtLoad = false;
      StandardOutPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.cache/repomix-pipeline/launchd.err.log";
    };
  };
}
