# Agent harness from github:nwlnexus/agent-skills (flake input, source only): every agents/<name>.md becomes
# <claude dir>/agents/<name>.md, and fragments/session-contract.md is kept in a marked block at the end of
# <claude dir>/CLAUDE.md (./contract.sh). Each hook in `hooks` below (hooks/<name> in agent-skills) is linked to
# <claude dir>/hooks/ and merged into <claude dir>/settings.json as an entry for its event (matcher "*") by
# ./hook-wire.sh, which edits only its own entry and never replaces the file. ./settings-wire.sh adds the
# nix-owned permission allow rules and sets autoMode in the same file (settings.* options). Skills are linked by
# ./default.nix and home/agent-host.
# Design: nwlnexus/olympus-sdk docs/superpowers/specs/2026-10-26-agent-harness-knowledge-and-hosts-design.md
# (H1, H3, H4, H5, H19), issues olympus-sdk#560, #561 and #576.
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

  # Hooks from agent-skills hooks/: <name> is linked to <dir>/hooks/<name> and wired as an <event> entry, matcher
  # "*". The identity regex is the escaped file name, so an entry running an older store path or a hand-installed
  # copy of the same script (any directory) is replaced in place instead of doubled.
  hooks = lib.filter (h: builtins.pathExists "${agentSkills}/hooks/${h.name}") [
    {
      name = "progress-stale.sh";
      event = "Stop";
    }
    {
      name = "permission-denied-log.sh";
      event = "PermissionDenied";
    }
  ];
  # Where a hook lands in a Claude dir; the settings entry runs this path, so a flake bump never changes it.
  hookPath = dir: name: "${home}/${dir}/hooks/${name}";

  # autoMode source: config/claude/auto-mode.json of the private olympus-sdk input. Until the pinned olympus-sdk
  # has that file (it lands with olympus-sdk#584), the default is null and autoMode is left untouched.
  autoModeDefault = "${inputs.olympus-sdk}/config/claude/auto-mode.json";
  autoMode =
    if cfg.settings.autoModeFile == null then
      null
    else
      import ./auto-mode.nix { inherit lib; } cfg.settings.autoModeFile cfg.settings.autoModeHost;
  allowJson = pkgs.writeText "claude-allow.json" (builtins.toJSON cfg.settings.allow);
  autoModeJson = pkgs.writeText "claude-auto-mode.json" (builtins.toJSON autoMode);
  wireSettings = cfg.settings.enable && (cfg.settings.allow != [ ] || autoMode != null);

  hookWire = pkgs.writeShellApplication {
    name = "hook-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./hook-wire.sh;
  };

  settingsWire = pkgs.writeShellApplication {
    name = "settings-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./settings-wire.sh;
  };

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
    hooks = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = hooks;
      description = "Hooks found in the agent-skills input and wired into settings.json (for tests).";
    };

    settings = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Add `allow` to `.permissions.allow` and set `.autoMode` in each Claude dir's settings.json at activation.
          Turning it off stops the wiring; rules and autoMode already written stay.
        '';
      };
      allow = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "Bash(gh pr create *)"
          "Bash(gh pr ready *)"
          "Bash(gh pr merge *)"
          "Bash(gh pr update-branch *)"
          "Bash(gh pr edit *)"
          "Bash(gh pr comment *)"
          "Bash(gh pr checks *)"
          "Bash(gh issue *)"
          "Bash(gh run *)"
          "Bash(git push -u origin *)"
        ];
        description = ''
          Permission rules merged into `.permissions.allow` (union: missing rules are appended, nothing is
          removed; olympus-sdk#576 layer 1).
        '';
      };
      autoModeFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = if builtins.pathExists autoModeDefault then autoModeDefault else null;
        defaultText = lib.literalMD "`config/claude/auto-mode.json` of the `olympus-sdk` input when it exists, else `null`";
        description = ''
          JSON source of `.autoMode` (`allow`, `environment`, `hostContainment`; see ./auto-mode.nix). `null`
          leaves `.autoMode` untouched; otherwise nix owns the whole key and replaces it (layer 2).
        '';
      };
      autoModeHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Key of `hostContainment` in the autoMode source; `null` (or a missing key) uses `default`.";
      };
      autoMode = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        readOnly = true;
        internal = true;
        default = autoMode;
        description = "The `.autoMode` value written to settings.json, or null (for tests).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge (
      map (
        dir:
        lib.listToAttrs (
          map (f: lib.nameValuePair "${dir}/agents/${f}" { source = "${agentsDir}/${f}"; }) agentFiles
        )
        // lib.listToAttrs (
          map (
            h: lib.nameValuePair "${dir}/hooks/${h.name}" { source = "${agentSkills}/hooks/${h.name}"; }
          ) hooks
        )
      ) cfg.dirs
    );

    # One entry per hook in each dir's settings.json (Claude Code owns that file: jq-merge, own entry only).
    # Fail-soft: a settings.json that does not parse is left alone.
    home.activation.claudeHooks = lib.mkIf (hooks != [ ]) (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] (
        lib.concatMapStringsSep "\n" (
          dir:
          lib.concatMapStringsSep "\n" (h: ''
            run ${hookWire}/bin/hook-wire ${h.event} '*' ${lib.escapeShellArg (lib.strings.escapeRegex h.name)} ${lib.escapeShellArg (hookPath dir h.name)} ${lib.escapeShellArg "${home}/${dir}/settings.json"} || true
          '') hooks
        ) cfg.dirs
      )
    );

    # Allow rules (union) and autoMode (replaced) in each dir's settings.json; same jq-merge rules as the hooks.
    # `-` = no autoMode source, leave the key alone.
    home.activation.claudeSettings = lib.mkIf wireSettings (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] ''
        run ${settingsWire}/bin/settings-wire ${allowJson} ${
          if autoMode == null then "-" else "${autoModeJson}"
        } ${
          lib.concatMapStringsSep " " (dir: lib.escapeShellArg "${home}/${dir}/settings.json") cfg.dirs
        } || true
      ''
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
