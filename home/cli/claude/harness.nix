# Agent harness, declared as Claude Code plugins (olympus-sdk#753, design
# docs/superpowers/specs/2026-11-07-claude-code-plugins-design.md P13/P14): ./plugin-wire.sh merges
# `extraKnownMarketplaces` and `enabledPlugins` into <claude dir>/settings.json. Every dir gets the public `nwlnexus`
# marketplace (github nwlnexus/agent-plugins) with `agent-harness` (long-task and gitnexus-no-churn skills, the
# claim-verifier agent, the session contract as a SessionStart hook, the progress-stale and permission-denied-log
# hooks). Dirs in `plugins.private.dirs` (personal dirs on hosts that set `plugins.private.enable`) also get the
# private `olympus-private` marketplace (github nwlnexus/olympus-memory) with `olympus-memory`; a work-only host and
# any `~/.claude-work` never do. Claude Code clones a declared marketplace and downloads the enabled plugins itself.
#
# The same activation takes out what the old nix harness wired from the agent-skills input (hook entries running
# <dir>/hooks/<name>; ./contract.sh drops the session-contract block from <dir>/CLAUDE.md); home-manager removes
# the old agents/, hooks/ and skills/ links itself. ./settings-wire.sh adds the nix-owned permission allow rules and
# sets autoMode in the same file (settings.* options); ./telemetry-wire.sh sets the Claude Code OTLP telemetry env
# (H12) in each dir's settings.json `env`, from config/claude/telemetry.json of the private olympus-sdk input.
# Earlier design: docs/superpowers/specs/2026-10-26-agent-harness-knowledge-and-hosts-design.md (H1, H3, H4, H5,
# H12, H19), issues olympus-sdk#560, #561, #565 and #576.
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
  home = config.home.homeDirectory;
  # Optional: home/agent-host is not imported on every platform.
  agentHost = config.d.agentHost or { enable = false; };

  # Hook files the old harness linked to <dir>/hooks/<name> and wired by absolute path; their settings entries are
  # removed (the agent-harness plugin runs them now).
  legacyHooks = [
    "progress-stale.sh"
    "permission-denied-log.sh"
  ];
  hookPath = dir: name: "${home}/${dir}/hooks/${name}";

  pcfg = cfg.plugins;
  publicMarketplace = {
    nwlnexus = {
      source = {
        source = "github";
        repo = "nwlnexus/agent-plugins";
      };
      autoUpdate = true;
    };
  };
  privateMarketplace = {
    olympus-private = {
      source = {
        source = "github";
        repo = "nwlnexus/olympus-memory";
      };
      autoUpdate = true;
    };
  };
  pluginSpec =
    dir:
    let
      private = lib.elem dir pcfg.private.dirs;
    in
    {
      marketplaces = publicMarketplace // lib.optionalAttrs private privateMarketplace;
      enable = {
        "agent-harness@nwlnexus" = true;
      }
      // lib.optionalAttrs private { "olympus-memory@olympus-private" = true; };
      removeHookCommands = map (hookPath dir) legacyHooks;
    };
  pluginSpecJson = dir: pkgs.writeText "claude-plugins.json" (builtins.toJSON (pluginSpec dir));
  # Tool names of the plugin's memory server (design P6/P7), allowed for headless sessions. Memory tools reached
  # through an MCP portal (`mcp__<portal>__memory_<tool>`) are deliberately not allowed here (olympus-sdk#924).
  privateAllow = lib.optionals (pcfg.private.dirs != [ ]) [
    "mcp__plugin_olympus-memory_memory__list_recent"
    "mcp__plugin_olympus-memory_memory__search"
    "mcp__plugin_olympus-memory_memory__recall"
  ];

  # autoMode source: config/claude/auto-mode.json of the private olympus-sdk input. Until the pinned olympus-sdk
  # has that file (it landed with olympus-sdk#585), the default is null and autoMode is left untouched.
  autoModeDefault = "${inputs.olympus-sdk}/config/claude/auto-mode.json";
  autoMode =
    if cfg.settings.autoModeFile == null then
      null
    else
      import ./auto-mode.nix { inherit lib; } cfg.settings.autoModeFile cfg.settings.autoModeHost;
  allowJson = pkgs.writeText "claude-allow.json" (
    builtins.toJSON (cfg.settings.allow ++ privateAllow)
  );
  autoModeJson = pkgs.writeText "claude-auto-mode.json" (builtins.toJSON autoMode);
  extraJson = pkgs.writeText "claude-settings-extra.json" (builtins.toJSON cfg.settings.extra);
  wireSettings =
    cfg.settings.enable
    && (cfg.settings.allow ++ privateAllow != [ ] || autoMode != null || cfg.settings.extra != { });

  # Telemetry source: config/claude/telemetry.json of the private olympus-sdk input ({ endpoint, protocol,
  # resourceAttributes }). Until the pinned olympus-sdk has that file (olympus-sdk#565) and in CI, where the input
  # is a stub, the default is null and no telemetry is wired.
  telemetryDefault = "${inputs.olympus-sdk}/config/claude/telemetry.json";
  tcfg = cfg.telemetry;
  tsrc = if tcfg.file == null then null else lib.importJSON tcfg.file;
  # The account of a dir: <acct> for the agent host's ~/.claude-<acct>, else the single account of that machine.
  accountOf =
    dir: if lib.hasPrefix ".claude-" dir then lib.removePrefix ".claude-" dir else tcfg.account;
  # The env Claude Code gets: metrics and events over OTLP to the collector. Cardinality is kept down: no session
  # id (the collector sums the delta counters of concurrent processes into one series per label set), no account
  # uuid; the repository is on (dashboard split by repo). Resource attribute values must not contain spaces.
  telemetryEnv =
    dir:
    let
      attrs =
        (tsrc.resourceAttributes or { })
        // lib.optionalAttrs (tcfg.host != null) { "host.name" = tcfg.host; }
        // {
          account = accountOf dir;
        };
    in
    assert lib.assertMsg (lib.all (v: !(lib.hasInfix " " v)) (
      lib.attrValues attrs
    )) "d.claudeHarness.telemetry: resource attribute values must not contain spaces";
    {
      CLAUDE_CODE_ENABLE_TELEMETRY = "1";
      OTEL_METRICS_EXPORTER = "otlp";
      OTEL_LOGS_EXPORTER = "otlp";
      OTEL_EXPORTER_OTLP_PROTOCOL = tsrc.protocol or "grpc";
      OTEL_EXPORTER_OTLP_ENDPOINT = tsrc.endpoint;
      OTEL_METRICS_INCLUDE_REPOSITORY = "true";
      OTEL_METRICS_INCLUDE_SESSION_ID = "false";
      OTEL_METRICS_INCLUDE_ACCOUNT_UUID = "false";
      OTEL_RESOURCE_ATTRIBUTES = lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") attrs);
    };
  telemetryEnvJson =
    dir: pkgs.writeText "claude-telemetry-env.json" (builtins.toJSON (telemetryEnv dir));

  pluginWire = pkgs.writeShellApplication {
    name = "plugin-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./plugin-wire.sh;
  };

  settingsWire = pkgs.writeShellApplication {
    name = "settings-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./settings-wire.sh;
  };

  telemetryWire = pkgs.writeShellApplication {
    name = "telemetry-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./telemetry-wire.sh;
  };

  contractUnwire = pkgs.writeShellApplication {
    name = "contract-unwire";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = builtins.readFile ./contract.sh;
  };
in
{
  options.d.claudeHarness = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declare the agent harness plugins (and wire settings, telemetry) in the Claude config dirs.";
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
    plugins = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Declare the plugin marketplaces and enabled plugins in each dir's settings.json (and remove the old nix
          harness wiring). Off: nothing is written; what was written stays.
        '';
      };
      private = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Also declare the private `olympus-private` marketplace and enable `olympus-memory` (personal hosts only;
            asserted off on work-only and server hosts).
          '';
        };
        dirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = if pcfg.private.enable then lib.filter (d: !(lib.hasSuffix "-work" d)) cfg.dirs else [ ];
          defaultText = lib.literalMD "every dir of `dirs` not ending in `-work` when `private.enable`, else none";
          description = "Dirs that get the private marketplace and `olympus-memory`.";
        };
      };
      spec = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        readOnly = true;
        internal = true;
        default = lib.genAttrs cfg.dirs pluginSpec;
        description = "What plugin-wire merges into each dir's settings.json, by dir (for tests).";
      };
    };

    telemetry = {
      file = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = if builtins.pathExists telemetryDefault then telemetryDefault else null;
        defaultText = lib.literalMD "`config/claude/telemetry.json` of the `olympus-sdk` input when it exists, else `null`";
        description = ''
          JSON source of the telemetry env (`endpoint`, `protocol`, `resourceAttributes`; olympus-sdk#565, H12).
          `null` wires nothing: Claude Code does not export telemetry.
        '';
      };
      account = lib.mkOption {
        type = lib.types.str;
        default = "personal";
        description = ''
          The `account` resource attribute for a dir that is not an agent-host account dir (the Macs' ~/.claude).
          Account dirs `~/.claude-<acct>` use `<acct>`.
        '';
      };
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.settings.autoModeHost;
        defaultText = lib.literalMD "`settings.autoModeHost`";
        description = "The `host.name` resource attribute; null leaves it out.";
      };
      env = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        readOnly = true;
        internal = true;
        default = if tsrc == null then { } else lib.genAttrs cfg.dirs telemetryEnv;
        description = "The telemetry env written to each dir's settings.json, by dir (for tests).";
      };
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
          # HW8 (olympus-sdk#566): the long-task skill's registry check and step-0 PR/branch checks must run in
          # headless (-p) sessions too, where default mode refuses unmatched MCP tools and Bash.
          "Bash(git fetch *)"
          "Bash(git ls-remote *)"
          "Bash(gh pr list *)"
          "Bash(gh pr view *)"
        ];
        description = ''
          Permission rules merged into `.permissions.allow` (union: missing rules are appended, nothing is
          removed; olympus-sdk#576 layer 1).
        '';
      };
      extra = lib.mkOption {
        type = lib.types.attrs;
        default = {
          # Per-session-kind peer policy (olympus-sdk#574, spec H16). Interactive sessions get the safe user-level
          # default here: no peer-machine discovery/messaging (isolatePeerMachines), and `crossSessionInbound` is
          # deliberately NOT set, so they keep the per-message default (ask before acting on a peer's message).
          # Unattended sessions opt in themselves: the goal runner (olympus-sdk scripts/goal-runner, #572) passes
          # `"crossSessionInbound":"accept"` in its own --settings, because nobody is there to approve.
          isolatePeerMachines = true;
        };
        description = ''
          Top-level settings.json keys set (deep-merged) in each dir at activation. See the default's comment for
          the per-session-kind peer policy.
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
    assertions = [
      {
        assertion =
          pcfg.private.dirs == [ ]
          || !(config.d.workOnly.enable or false) && !(config.d.server.enable or false);
        message = "d.claudeHarness.plugins.private: never on a work-only or server host (design P13).";
      }
      {
        assertion = !(lib.any (lib.hasSuffix "-work") pcfg.private.dirs);
        message = "d.claudeHarness.plugins.private.dirs: never a work account dir (design P13).";
      }
    ];

    # Marketplaces + enabled plugins in each dir's settings.json, and the old harness hook entries out (Claude Code
    # owns that file: jq-merge, named entries only). Fail-soft: a settings.json that does not parse is left alone.
    home.activation.claudePlugins = lib.mkIf pcfg.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] (
        lib.concatMapStringsSep "\n" (dir: ''
          run ${pluginWire}/bin/plugin-wire ${pluginSpecJson dir} ${lib.escapeShellArg "${home}/${dir}/settings.json"} || true
        '') cfg.dirs
        + ''
          run ${contractUnwire}/bin/contract-unwire session-contract ${
            lib.concatMapStringsSep " " (dir: lib.escapeShellArg "${home}/${dir}/CLAUDE.md") cfg.dirs
          } || true
        ''
      )
    );

    # Allow rules (union) and autoMode (replaced) in each dir's settings.json; same jq-merge rules as the hooks.
    # `-` = no autoMode source, leave the key alone.
    home.activation.claudeSettings = lib.mkIf wireSettings (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] ''
        run ${settingsWire}/bin/settings-wire ${allowJson} ${
          if autoMode == null then "-" else "${autoModeJson}"
        } ${lib.optionalString (cfg.settings.extra != { }) "--set ${extraJson}"} ${
          lib.concatMapStringsSep " " (dir: lib.escapeShellArg "${home}/${dir}/settings.json") cfg.dirs
        } || true
      ''
    );

    # Telemetry env (olympus-sdk#565) in each dir's settings.json `env`; the account differs per dir, so one call
    # per dir. Same jq-merge rules as the hooks and settings.
    home.activation.claudeTelemetry = lib.mkIf (tsrc != null) (
      lib.hm.dag.entryAfter [ "writeBoundary" "agentHostDirs" ] (
        lib.concatMapStringsSep "\n" (dir: ''
          run ${telemetryWire}/bin/telemetry-wire ${telemetryEnvJson dir} ${lib.escapeShellArg "${home}/${dir}/settings.json"} || true
        '') cfg.dirs
      )
    );
  };
}
