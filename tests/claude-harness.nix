# Agent harness from agent-skills (home/cli/claude/harness.nix): agents/, the session-contract block in
# CLAUDE.md, the hooks and the settings wiring (allow rules, autoMode), for the account dirs on the agent host
# (never ~/.claude there) and ~/.claude on a Mac. The autoMode variants use a made-up fixture
# (tests/fixtures/claude-auto-mode.json) through extendModules; nothing is built or activated.
{ flake, lib }:
let
  deployed = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  host = deployed.config;
  mac = flake.darwinConfigurations.NWL-MMINI.config.home-manager.users.nwilliams-lucas;
  h = "/home/nwilliams-lucas";
  m = "/Users/nwilliams-lucas";
  contract = c: c.home.activation.claudeSessionContract.data or "";
  hooksData = c: c.home.activation.claudeHooks.data or "";
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
  testHarnessAgentsFound = {
    expr = lib.elem "claim-verifier.md" host.d.claudeHarness.agents;
    expected = true;
  };
  testHarnessHostDirs = {
    expr = host.d.claudeHarness.dirs;
    expected = [
      ".claude-personal"
      ".claude-work"
    ];
  };
  testHarnessHostAgents = {
    expr = map (f: host.home.file ? ${f}) [
      ".claude-personal/agents/claim-verifier.md"
      ".claude-work/agents/claim-verifier.md"
      ".claude/agents/claim-verifier.md"
    ];
    expected = [
      true
      true
      false
    ];
  };
  testHarnessHostContract = {
    expr = map (f: lib.hasInfix f (contract host)) [
      " ${h}/.claude-personal/CLAUDE.md"
      " ${h}/.claude-work/CLAUDE.md"
      " ${h}/.claude/CLAUDE.md"
      "fragments/session-contract.md"
    ];
    expected = [
      true
      true
      false
      true
    ];
  };
  testHarnessContractAfterAccountDirs = {
    expr = lib.elem "agentHostDirs" host.home.activation.claudeSessionContract.after;
    expected = true;
  };
  # The long-task skill reaches the account dirs through the existing skills wiring.
  testHarnessHostSkill = {
    expr = map (f: host.home.file ? ${f}) [
      ".claude-personal/skills/long-task"
      ".claude-work/skills/long-task"
    ];
    expected = [
      true
      true
    ];
  };
  testHarnessMac = {
    expr = [
      mac.d.claudeHarness.dirs
      (mac.home.file ? ".claude/agents/claim-verifier.md")
      (mac.home.file ? ".claude/skills/long-task")
      (lib.hasInfix " ${m}/.claude/CLAUDE.md" (contract mac))
    ];
    expected = [
      [ ".claude" ]
      true
      true
      true
    ];
  };

  # The progress-stale Stop hook: linked into each account dir (never ~/.claude on the host) and merged into
  # settings.json by hook-wire for exactly those dirs, as a Stop entry with matcher "*".
  testHarnessHostHookLinks = {
    expr = map (f: host.home.file ? ${f}) [
      ".claude-personal/hooks/progress-stale.sh"
      ".claude-work/hooks/progress-stale.sh"
      ".claude/hooks/progress-stale.sh"
    ];
    expected = [
      true
      true
      false
    ];
  };
  testHarnessHostHookWire = {
    expr =
      let
        data = hooksData host;
      in
      map (f: lib.hasInfix f data) [
        "hook-wire Stop '*' 'progress-stale\\.sh' ${h}/.claude-personal/hooks/progress-stale.sh ${h}/.claude-personal/settings.json"
        "hook-wire Stop '*' 'progress-stale\\.sh' ${h}/.claude-work/hooks/progress-stale.sh ${h}/.claude-work/settings.json"
        "/.claude/settings.json"
      ];
    expected = [
      true
      true
      false
    ];
  };
  testHarnessMacHook = {
    expr = [
      (mac.home.file ? ".claude/hooks/progress-stale.sh")
      (lib.hasInfix "hook-wire Stop '*' 'progress-stale\\.sh' ${m}/.claude/hooks/progress-stale.sh ${m}/.claude/settings.json" (
        hooksData mac
      ))
    ];
    expected = [
      true
      true
    ];
  };

  # The permission-denied-log hook (olympus-sdk#576 layer 3): linked like progress-stale and wired as a
  # PermissionDenied entry. Its identity regex also matches a hand-installed copy elsewhere, so that entry is
  # replaced, not doubled.
  testHarnessHooksFound = {
    expr = host.d.claudeHarness.hooks;
    expected = [
      {
        name = "progress-stale.sh";
        event = "Stop";
      }
      {
        name = "permission-denied-log.sh";
        event = "PermissionDenied";
      }
    ];
  };
  testHarnessHostDenialHook = {
    expr =
      map (f: host.home.file ? ${f}) [
        ".claude-personal/hooks/permission-denied-log.sh"
        ".claude-work/hooks/permission-denied-log.sh"
        ".claude/hooks/permission-denied-log.sh"
      ]
      ++ map (f: lib.hasInfix f (hooksData host)) [
        "hook-wire PermissionDenied '*' 'permission-denied-log\\.sh' ${h}/.claude-personal/hooks/permission-denied-log.sh ${h}/.claude-personal/settings.json"
        "hook-wire PermissionDenied '*' 'permission-denied-log\\.sh' ${h}/.claude-work/hooks/permission-denied-log.sh ${h}/.claude-work/settings.json"
      ];
    expected = [
      true
      true
      false
      true
      true
    ];
  };
  testHarnessDenialRegexMatchesHandCopy = {
    expr =
      builtins.match ".*${lib.strings.escapeRegex "permission-denied-log.sh"}.*" "${h}/.local/libexec/agent-hooks/permission-denied-log.sh"
      != null;
    expected = true;
  };
  testHarnessMacDenialHook = {
    expr = [
      (mac.home.file ? ".claude/hooks/permission-denied-log.sh")
      (lib.hasInfix "hook-wire PermissionDenied '*' 'permission-denied-log\\.sh' ${m}/.claude/hooks/permission-denied-log.sh ${m}/.claude/settings.json" (
        hooksData mac
      ))
    ];
    expected = [
      true
      true
    ];
  };
  # Both settings.json activations run after agentHostDirs, so a new account dir already exists with mode 0700.
  testHarnessWiringAfterAccountDirs = {
    expr = map (a: lib.elem "agentHostDirs" host.home.activation.${a}.after) [
      "claudeHooks"
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
      (lib.hasInfix "-claude-auto-mode.json ${h}/.claude-personal/settings.json" (settingsData onHost))
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
      (settingsOff.home.activation ? claudeHooks)
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
          [
            ".claude-personal"
            ".claude-work"
          ]
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
        ".claude-work" = base // {
          OTEL_RESOURCE_ATTRIBUTES = "account=work,deployment.environment=example,host.name=ai-agent-host";
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
      true
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
