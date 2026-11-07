# Agent harness (home/cli/claude/harness.nix): the plugin declarations (olympus-sdk#753; marketplaces, enabled
# plugins, removal of the old nix harness hook entries and CLAUDE.md block) and the settings wiring (allow rules,
# autoMode), for the account dirs on the agent host
# (never ~/.claude there) and ~/.claude on a Mac. The autoMode variants use a made-up fixture
# (tests/fixtures/claude-auto-mode.json) through extendModules; nothing is built or activated.
{ flake, lib }:
let
  deployed = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  host = deployed.config;
  mac = flake.darwinConfigurations.nwl-mstudio.config.home-manager.users.nwilliams-lucas;
  h = "/home/nwilliams-lucas";
  m = "/Users/nwilliams-lucas";
  pluginsData = c: c.home.activation.claudePlugins.data or "";
  spec = c: c.d.claudeHarness.plugins.spec;
  public = {
    nwlnexus = {
      source = {
        source = "github";
        repo = "nwlnexus/agent-plugins";
      };
      autoUpdate = true;
    };
  };
  private = {
    olympus-private = {
      source = {
        source = "github";
        repo = "nwlnexus/olympus-memory";
      };
      autoUpdate = true;
    };
  };
  # A generic agent host with a personal and a work account, private plugins on.
  twoAccounts =
    (deployed.extendModules {
      modules = [
        {
          d.personalOnly.enable = lib.mkOverride 40 false;
          d.claudeHarness.dirs = lib.mkOverride 40 [
            ".claude-personal"
            ".claude-work"
          ];
        }
      ];
    }).config;
  settingsData = c: c.home.activation.claudeSettings.data or "";
  with' =
    settings:
    (deployed.extendModules {
      modules = [ { d.claudeHarness.settings = lib.mapAttrs (_: lib.mkOverride 40) settings; } ];
    }).config;
  fixture = ./fixtures/claude-auto-mode.json;
  onHost = with' { autoModeFile = fixture; };
  onOther = with' {
    autoModeFile = fixture;
    autoModeHost = "no-such-host";
  };
  settingsOff = with' { enable = false; };
  telemetryFixture = ./fixtures/claude-telemetry.json;
  withTelemetry =
    c: telemetry: dirs:
    (c.extendModules {
      modules = [
        {
          d.claudeHarness = {
            telemetry = lib.mapAttrs (_: lib.mkOverride 40) telemetry;
          }
          // lib.optionalAttrs (dirs != null) { dirs = lib.mkOverride 40 dirs; };
        }
      ];
    }).config;
  telHost = withTelemetry deployed { file = telemetryFixture; } null;
  telHostOff = withTelemetry deployed { file = null; } null;
  telData = c: c.home.activation.claudeTelemetry.data or "";
  # The pinned olympus-sdk may or may not carry the autoMode source (added in olympus-sdk#585).
  sdkHasAutoMode = builtins.pathExists "${flake.inputs.olympus-sdk}/config/claude/auto-mode.json";
  sdkHasTelemetry = builtins.pathExists "${flake.inputs.olympus-sdk}/config/claude/telemetry.json";
in
{
  testHarnessHostDirs = {
    expr = host.d.claudeHarness.dirs;
    expected = [ ".claude-personal" ];
  };

  # Personal dirs declare both marketplaces and enable both plugins; the old harness hook entries are removed.
  testHarnessPluginsHost = {
    expr = spec host;
    expected = {
      ".claude-personal" = {
        marketplaces = public // private;
        enable = {
          "agent-harness@nwlnexus" = true;
          "olympus-memory@olympus-private" = true;
        };
        removeHookCommands = [
          "${h}/.claude-personal/hooks/progress-stale.sh"
          "${h}/.claude-personal/hooks/permission-denied-log.sh"
        ];
      };
    };
  };
  testHarnessPluginsMac = {
    expr = [
      mac.d.claudeHarness.dirs
      (spec mac).".claude".marketplaces
      (spec mac).".claude".enable
    ];
    expected = [
      [ ".claude" ]
      (public // private)
      {
        "agent-harness@nwlnexus" = true;
        "olympus-memory@olympus-private" = true;
      }
    ];
  };
  # A work account dir never gets the private marketplace, even with private plugins on for the host.
  testHarnessPluginsWorkDir = {
    expr = [
      twoAccounts.d.claudeHarness.plugins.private.dirs
      (spec twoAccounts).".claude-work".marketplaces
      (spec twoAccounts).".claude-work".enable
      (lib.hasInfix "olympus" (builtins.toJSON (spec twoAccounts).".claude-work"))
    ];
    expected = [
      [ ".claude-personal" ]
      public
      { "agent-harness@nwlnexus" = true; }
      false
    ];
  };
  testHarnessPluginsWire = {
    expr = map (f: lib.hasInfix f (pluginsData host)) [
      "/bin/plugin-wire /nix/store/"
      "-claude-plugins.json ${h}/.claude-personal/settings.json"
      "/bin/contract-unwire session-contract ${h}/.claude-personal/CLAUDE.md"
      "/.claude/settings.json"
      "/.claude/CLAUDE.md"
    ];
    expected = [
      true
      true
      true
      false
      false
    ];
  };
  # Nothing is linked from the retired agent-skills input any more.
  testHarnessNoVendoredFiles = {
    expr =
      map
        (
          c:
          lib.filter (t: builtins.match ".*/(agents|hooks|skills)/.*" "/${t}" != null) (
            lib.attrNames c.home.file
          )
        )
        [
          host
          mac
        ];
    expected = [
      [ ]
      [ ]
    ];
  };
  testHarnessNoAgentSkillsInput = {
    expr = flake.inputs ? agent-skills;
    expected = false;
  };
  # Both settings.json activations run after agentHostDirs, so a new account dir already exists with mode 0700.
  testHarnessWiringAfterAccountDirs = {
    expr = map (a: lib.elem "agentHostDirs" host.home.activation.${a}.after) [
      "claudePlugins"
      "claudeSettings"
    ];
    expected = [
      true
      true
    ];
  };

  # Allow rules and autoMode (layers 1 and 2): settings-wire over each account dir's settings.json.
  testHarnessSettingsAllowDefault = {
    expr = host.d.claudeHarness.settings.allow;
    expected = [
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
      "Bash(git fetch *)"
      "Bash(git ls-remote *)"
      "Bash(gh pr list *)"
      "Bash(gh pr view *)"
    ];
  };
  testHarnessSettingsHostWire = {
    expr = map (f: lib.hasInfix f (settingsData host)) [
      "/bin/settings-wire /nix/store/"
      "-claude-allow.json "
      " ${h}/.claude-personal/settings.json ${h}/.claude-work/settings.json"
      "/.claude/settings.json"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };
  # Per-session-kind peer policy (olympus-sdk#574, H16): isolatePeerMachines everywhere, crossSessionInbound never.
  testHarnessSettingsPeerPolicy = {
    expr = [
      host.d.claudeHarness.settings.extra
      (lib.hasInfix " --set /nix/store/" (settingsData host))
      (lib.hasInfix "crossSessionInbound" (builtins.toJSON host.d.claudeHarness.settings.extra))
    ];
    expected = [
      { isolatePeerMachines = true; }
      true
      false
    ];
  };
  testHarnessSettingsHost = {
    expr = host.d.claudeHarness.settings.autoModeHost;
    expected = "ai-agent-host";
  };
  # Without the source file in the pinned olympus-sdk, autoMode is left alone (`-`).
  testHarnessSettingsAutoModeGuard = {
    expr = [
      (host.d.claudeHarness.settings.autoMode == null)
      (lib.hasInfix "-claude-allow.json - " (settingsData host))
    ];
    expected = [
      (!sdkHasAutoMode)
      (!sdkHasAutoMode)
    ];
  };
  testHarnessSettingsAutoModeHost = {
    expr = [
      onHost.d.claudeHarness.settings.autoMode
      (lib.hasInfix "-claude-auto-mode.json --set /nix/store/" (settingsData onHost))
    ];
    expected = [
      {
        allow = [
          "$defaults"
          "Example allow rule"
        ];
        environment = [
          "**Example**: made-up environment entry"
          "**Host containment**: example containment for the agent host"
        ];
      }
      true
    ];
  };
  testHarnessSettingsAutoModeDefaultHost = {
    expr = onOther.d.claudeHarness.settings.autoMode.environment;
    expected = [
      "**Example**: made-up environment entry"
      "**Host containment**: example default containment"
    ];
  };
  testHarnessSettingsOff = {
    expr = [
      (settingsOff.home.activation ? claudeSettings)
      (settingsOff.home.activation ? claudePlugins)
    ];
    expected = [
      false
      true
    ];
  };
  testHarnessMacSettings = {
    expr = [
      mac.d.claudeHarness.settings.autoModeHost
      (lib.hasInfix " ${m}/.claude/settings.json" (settingsData mac))
    ];
    expected = [
      null
      true
    ];
  };

  # Telemetry (olympus-sdk#565, H12): the OTLP env in each dir's settings.json `env`, from the private
  # olympus-sdk input (here a made-up fixture). Without the file (CI stub, older pin) nothing is wired.
  testHarnessTelemetryGuard = {
    expr = [
      (lib.attrNames host.d.claudeHarness.telemetry.env)
      (host.home.activation ? claudeTelemetry)
    ];
    expected =
      if sdkHasTelemetry then
        [
          [ ".claude-personal" ]
          true
        ]
      else
        [
          [ ]
          false
        ];
  };
  testHarnessTelemetryOff = {
    expr = [
      telHostOff.d.claudeHarness.telemetry.env
      (telHostOff.home.activation ? claudeTelemetry)
    ];
    expected = [
      { }
      false
    ];
  };
  testHarnessTelemetryEnvPerAccount = {
    expr = telHost.d.claudeHarness.telemetry.env;
    expected =
      let
        base = {
          CLAUDE_CODE_ENABLE_TELEMETRY = "1";
          OTEL_METRICS_EXPORTER = "otlp";
          OTEL_LOGS_EXPORTER = "otlp";
          OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
          OTEL_EXPORTER_OTLP_ENDPOINT = "http://collector.example:4317";
          OTEL_METRICS_INCLUDE_REPOSITORY = "true";
          OTEL_METRICS_INCLUDE_SESSION_ID = "false";
          OTEL_METRICS_INCLUDE_ACCOUNT_UUID = "false";
        };
      in
      {
        ".claude-personal" = base // {
          OTEL_RESOURCE_ATTRIBUTES = "account=personal,deployment.environment=example,host.name=ai-agent-host";
        };
      };
  };
  testHarnessTelemetryHostWire = {
    expr = map (f: lib.hasInfix f (telData telHost)) [
      "/bin/telemetry-wire /nix/store/"
      "-claude-telemetry-env.json ${h}/.claude-personal/settings.json"
      "-claude-telemetry-env.json ${h}/.claude-work/settings.json"
      "/.claude/settings.json"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };
  testHarnessTelemetryAfterAccountDirs = {
    expr = lib.elem "agentHostDirs" telHost.home.activation.claudeTelemetry.after;
    expected = true;
  };
  # The Mac layout (one ~/.claude, no host name): the host config with dirs and host overridden. The account is
  # the option (personal by default); the Mac config itself carries no telemetry until the pinned input has it.
  testHarnessTelemetryMacLayout = {
    expr =
      let
        macLike =
          account:
          (withTelemetry deployed {
            file = telemetryFixture;
            host = null;
            inherit account;
          } [ ".claude" ]);
        personal = macLike "personal";
        work = macLike "work";
      in
      [
        (lib.attrNames personal.d.claudeHarness.telemetry.env)
        personal.d.claudeHarness.telemetry.env.".claude".OTEL_RESOURCE_ATTRIBUTES
        work.d.claudeHarness.telemetry.env.".claude".OTEL_RESOURCE_ATTRIBUTES
        (lib.hasInfix " ${h}/.claude/settings.json" (telData personal))
        (mac.d.claudeHarness.telemetry.env == { } || sdkHasTelemetry)
      ];
    expected = [
      [ ".claude" ]
      "account=personal,deployment.environment=example"
      "account=work,deployment.environment=example"
      true
      true
    ];
  };

  # agent-session: ~/.local/bin on the host and the Mac, per-account config dir only on the host.
  testAgentSessionInstalled = {
    expr = [
      (host.home.file ? ".local/bin/agent-session")
      (mac.home.file ? ".local/bin/agent-session")
    ];
    expected = [
      true
      true
    ];
  };
}
