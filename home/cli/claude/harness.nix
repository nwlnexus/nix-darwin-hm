# Agent harness from github:nwlnexus/agent-skills (flake input, source only): every agents/<name>.md becomes
# <claude dir>/agents/<name>.md, and fragments/session-contract.md is kept in a marked block at the end of
# <claude dir>/CLAUDE.md (./contract.sh). Skills are linked by ./default.nix and home/agent-host.
# Design: nwlnexus/olympus-sdk docs/superpowers/specs/2026-10-26-agent-harness-knowledge-and-hosts-design.md
# (H1, H4, H5), issue olympus-sdk#560.
#
# Which Claude dirs: the per-account dirs on agent hosts (~/.claude-<acct>; ~/.claude stays unwired there,
# owner decision H17), ~/.claude everywhere else (the Macs).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.d.claudeHarness;
  agentSkills = inputs.agent-skills;
  home = config.home.homeDirectory;
  # Optional: home/agent-host is not imported on every platform.
  agentHost = config.d.agentHost or { enable = false; };

  agentsDir = "${agentSkills}/agents";
  agentFiles =
    if builtins.pathExists agentsDir then
      lib.attrNames (
        lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir agentsDir)
      )
    else
      [ ];

  fragmentName = "session-contract";
  fragment = "${agentSkills}/fragments/${fragmentName}.md";
  hasFragment = builtins.pathExists fragment;

  contractWire = pkgs.writeShellApplication {
    name = "contract-wire";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.diffutils
    ];
    text = builtins.readFile ./contract.sh;
  };
in
{
  options.d.claudeHarness = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the agent-skills agents and session contract into the Claude config dirs.";
    };
    dirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        if agentHost.enable then
          map (acct: ".claude-${acct}") (lib.attrNames agentHost.accounts)
        else
          [ ".claude" ];
      defaultText = lib.literalMD "`~/.claude-<acct>` per `d.agentHost.accounts` on agent hosts, else `~/.claude`";
      description = "Claude config dirs, relative to the home directory.";
    };
    agents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = agentFiles;
      description = "Agent files found in the agent-skills input (for tests).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge (
      map (
        dir:
        lib.listToAttrs (
          map (f: lib.nameValuePair "${dir}/agents/${f}" { source = "${agentsDir}/${f}"; }) agentFiles
        )
      ) cfg.dirs
    );

    # After agentHostDirs (when present), so a new account dir already exists with its 0700 mode.
    home.activation.claudeSessionContract = lib.mkIf hasFragment (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] ''
        run ${contractWire}/bin/contract-wire ${fragmentName} ${lib.escapeShellArg fragment} ${
          lib.concatMapStringsSep " " (dir: lib.escapeShellArg "${home}/${dir}/CLAUDE.md") cfg.dirs
        }
      ''
    );
  };
}
