# jev-router (home/agent-host/jev-router.nix, olympus-sdk#647): the generated config, the units, the routed env and
# the billing guard. Behaviour (the packaged router against local fakes): tests/jev-router.sh.
{ flake, lib }:
let
  deployed = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  hm = deployed.config;
  jr = hm.d.agentHost.jevRouter;
  svc = hm.systemd.user.services;
  h = "/home/nwilliams-lucas";
  str = v: lib.concatStringsSep " " (map toString (lib.toList v));
  with' = mods: (deployed.extendModules { modules = mods; }).config;
  # Whether the host's home configuration still evaluates (assertions abort the activation package).
  evaluates =
    mods:
    (builtins.tryEval (builtins.unsafeDiscardStringContext (with' mods).home.activationPackage.drvPath))
    .success;
  telemetry = ./fixtures/claude-telemetry.json;
  # The billing guard as a function (home/agent-host/jev-billing-guard.nix), fed what the deployed host would deploy
  # plus one fixture change. A configuration with a failed assertion throws as a whole, so the messages are checked
  # here; `evaluates` below checks end to end that such a configuration does not build.
  guard = import ../home/agent-host/jev-billing-guard.nix { inherit lib; };
  deployedInputs = {
    managed = {
      "d.claudeHarness.settings.extra" = lib.attrNames hm.d.claudeHarness.settings.extra;
      "d.claudeHarness.settings.extra.env" = lib.attrNames (hm.d.claudeHarness.settings.extra.env or { });
      "home.sessionVariables" = lib.attrNames hm.home.sessionVariables;
    }
    // lib.mapAttrs' (
      dir: env: lib.nameValuePair "d.claudeHarness.telemetry.env.${dir}" (lib.attrNames env)
    ) hm.d.claudeHarness.telemetry.env;
    unitEnv = lib.toList (svc.jev-router.Service.Environment or [ ]);
    secretEnv = jr.secretEnv;
    inherit (jr.settings) surfaces;
  };
  addManaged =
    where: name:
    deployedInputs
    // {
      managed = deployedInputs.managed // {
        ${where} = (deployedInputs.managed.${where} or [ ]) ++ [ name ];
      };
    };
  setTarget =
    tier: attrs:
    deployedInputs
    // {
      surfaces = lib.recursiveUpdate deployedInputs.surfaces { anthropic.${tier} = attrs; };
    };
  # Refused by exactly one rule, the one whose message contains `needle`.
  refusedBy =
    inputs: needle:
    let
      failed = guard inputs;
    in
    lib.length failed == 1 && lib.hasInfix needle (lib.head failed);
in
{
  testJevRouterOnlyOnAiAgentHost = {
    expr = [
      jr.enable
      jr.account
      jr.shadow
      jr.allowedRemotes
      flake.darwinConfigurations.nwl-mstudio.config.home-manager.users.nwilliams-lucas.d.agentHost.jevRouter.enable
    ];
    expected = [
      true
      "personal"
      false
      [
        "github.com/nwlnexus/agent-plugins"
        "github.com/nwlnexus/nix-darwin-hm"
        "github.com/nwlnexus/olympus-infra"
        "github.com/nwlnexus/olympus-sdk"
        "github.com/nwlnexus/olympus-gitops"
        "github.com/nwlnexus/olympus-tailnet"
      ]
      false
    ];
  };
  testJevRouterTiers = {
    expr = [
      jr.settings.tiers
      jr.settings.defaultTier
      jr.settings.policy.mode
      (lib.mapAttrs (_: o: o.tier) jr.settings.jev.options)
      (map (c: c.name) jr.settings.jev.channels)
      (map (c: c.keyEnv) jr.settings.jev.channels)
    ];
    expected = [
      [
        "light"
        "medium"
        "heavy"
      ]
      "medium"
      "ratchet"
      {
        mechanical = "light";
        routine = "medium";
        complex = "heavy";
        deep = "heavy";
      }
      [ "typesafe" ]
      [ "TYPESAFE_API_KEY" ]
    ];
  };
  # Shadow (the module default; the host is routed): every tier goes to the account default; background calls keep
  # Haiku.
  testJevRouterShadowTargets = {
    expr =
      lib.mapAttrs (_: t: t.model)
        (with' [
          { d.agentHost.jevRouter.shadow = lib.mkForce true; }
        ]).d.agentHost.jevRouter.settings.surfaces.anthropic;
    expected = {
      side = "claude-haiku-5-5";
      light = "claude-opus-5-5";
      medium = "claude-opus-5-5";
      heavy = "claude-opus-5-5";
    };
  };
  # Routed (the host, owner 2026-11-08): Jev's tier picks the model.
  testJevRouterRoutedTargets = {
    expr = lib.mapAttrs (_: t: t.model) jr.settings.surfaces.anthropic;
    expected = {
      side = "claude-haiku-5-5";
      light = "claude-haiku-5-5";
      medium = "claude-sonnet-5-5";
      heavy = "claude-opus-5-5";
    };
  };
  testJevRouterClientAuthOnly = {
    expr = lib.unique (
      lib.mapAttrsToList (_: t: [
        t.clientAuth
        (t ? keyEnv)
      ]) jr.settings.surfaces.anthropic
    );
    expected = [
      [
        true
        false
      ]
    ];
  };
  testJevRouterUnit = {
    expr =
      let
        s = svc.jev-router.Service;
      in
      [
        (lib.hasInfix "/bin/jev-router serve --config /nix/store/" (str s.ExecStart))
        (str s.EnvironmentFile)
        (str s.Restart)
        s.NoNewPrivileges
        svc.jev-router.Install.WantedBy
      ];
    expected = [
      true
      "-${h}/.config/jev-router/env"
      "always"
      true
      [ "default.target" ]
    ];
  };
  testJevRouterSecret = {
    expr =
      let
        s = hm.op-secrets.secrets.jev-router-env;
      in
      [
        s.dest
        s.mode
        (builtins.readFile s.template)
      ];
    expected = [
      "${h}/.config/jev-router/env"
      "0600"
      ''
        TYPESAFE_API_KEY="{{ op://Dev/jev-olympus/credential }}"
      ''
    ];
  };
  # The shipper reuses the Claude Code telemetry endpoint (gRPC 4317 -> OTLP/HTTP 4318); none without a source.
  testJevRouterShipper = {
    expr =
      let
        c = with' [ { d.claudeHarness.telemetry.file = lib.mkOverride 40 telemetry; } ];
        off = with' [ { d.claudeHarness.telemetry.file = lib.mkOverride 40 null; } ];
        s = c.systemd.user.services.jev-router-ship.Service;
      in
      [
        c.d.agentHost.jevRouter.shipper.endpoint
        (lib.hasInfix "--endpoint http://collector.example:4318/v1/logs" (str s.ExecStart))
        (lib.hasInfix "'service.name=jev-router'" (str s.ExecStart))
        (lib.hasInfix "/bin/python3 -I " (str s.ExecStart))
        (off.systemd.user.services ? jev-router-ship)
      ];
    expected = [
      "http://collector.example:4318"
      true
      true
      true
      false
    ];
  };
  testJevRouteEnvHook = {
    expr = map (x: lib.hasInfix x hm.programs.zsh.initContent) [
      "precmd_functions+=(_jev_route)"
      "/bin/jev-route-env \"$PWD\""
    ];
    expected = [
      true
      true
    ];
  };
  # Done-when 1, the billing guard: the deployed config evaluates; an Anthropic key, auth token or apiKeyHelper in
  # the router unit or the managed settings, a target with its own key, or omitBetas dropping OAuth, do not. Each
  # fixture must fail exactly one billing assertion, the one named after it.
  testJevRouterBillingGuard = {
    expr = [
      (evaluates [ ])
      (guard deployedInputs)
      (refusedBy (
        deployedInputs // { unitEnv = deployedInputs.unitEnv ++ [ "ANTHROPIC_API_KEY=sk-test" ]; }
      ) "router unit's Environment")
      (refusedBy (
        deployedInputs
        // {
          secretEnv = deployedInputs.secretEnv // {
            ANTHROPIC_API_KEY = "op://Dev/x/credential";
          };
        }
      ) "secretEnv must not carry")
      (refusedBy (addManaged "d.claudeHarness.settings.extra.env" "ANTHROPIC_API_KEY") "found in d.claudeHarness.settings.extra.env")
      (refusedBy (addManaged "d.claudeHarness.settings.extra.env" "ANTHROPIC_AUTH_TOKEN") "found in d.claudeHarness.settings.extra.env")
      (refusedBy (addManaged "d.claudeHarness.settings.extra" "apiKeyHelper") "found in d.claudeHarness.settings.extra)")
      (refusedBy (addManaged "home.sessionVariables" "ANTHROPIC_API_KEY") "found in home.sessionVariables")
      (refusedBy (addManaged "d.claudeHarness.telemetry.env..claude-personal" "ANTHROPIC_API_KEY") "found in d.claudeHarness.telemetry.env..claude-personal")
      (refusedBy (setTarget "heavy" { keyEnv = "ANTHROPIC_API_KEY"; }) "surfaces.anthropic.heavy")
      (refusedBy (setTarget "medium" { clientAuth = false; }) "surfaces.anthropic.medium")
      (refusedBy (setTarget "light" {
        omitBetas = [ "oauth-2025-04-20" ];
      }) "omitBetas must never drop the OAuth beta")
      # End to end: each kind of fixture stops the real activation package from evaluating.
      (evaluates [
        { systemd.user.services.jev-router.Service.Environment = [ "ANTHROPIC_API_KEY=sk-test" ]; }
      ])
      (evaluates [ { d.agentHost.jevRouter.secretEnv.ANTHROPIC_API_KEY = "op://Dev/x/credential"; } ])
      (evaluates [ { d.claudeHarness.settings.extra.env.ANTHROPIC_API_KEY = "x"; } ])
      (evaluates [ { d.claudeHarness.settings.extra.apiKeyHelper = "/bin/echo"; } ])
      (evaluates [ { home.sessionVariables.ANTHROPIC_API_KEY = "x"; } ])
      (evaluates [ { d.claudeHarness.telemetry.env.".claude-personal".ANTHROPIC_API_KEY = "x"; } ])
      (evaluates [
        { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.heavy.keyEnv = "ANTHROPIC_API_KEY"; }
      ])
      (evaluates [ { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.medium.clientAuth = false; } ])
      (evaluates [
        { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.light.omitBetas = [ "oauth-2025-04-20" ]; }
      ])
    ];
    expected = [
      true
      [ ]
      true
      true
      true
      true
      true
      true
      true
      true
      true
      true
      false
      false
      false
      false
      false
      false
      false
      false
      false
    ];
  };
}
