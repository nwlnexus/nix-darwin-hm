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
in
{
  testJevRouterOnlyOnAiAgentHost = {
    expr = [
      jr.enable
      jr.account
      jr.shadow
      flake.darwinConfigurations.nwl-mstudio.config.home-manager.users.nwilliams-lucas.d.agentHost.jevRouter.enable
    ];
    expected = [
      true
      "personal"
      true
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
  # Shadow (default): every tier goes to the account default; background calls keep Haiku.
  testJevRouterShadowTargets = {
    expr = lib.mapAttrs (_: t: t.model) jr.settings.surfaces.anthropic;
    expected = {
      side = "claude-haiku-5-5";
      light = "claude-opus-5-5";
      medium = "claude-opus-5-5";
      heavy = "claude-opus-5-5";
    };
  };
  testJevRouterRoutedTargets = {
    expr =
      lib.mapAttrs (_: t: t.model)
        (with' [
          { d.agentHost.jevRouter.shadow = false; }
        ]).d.agentHost.jevRouter.settings.surfaces.anthropic;
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
  # the router unit or the managed settings, a target with its own key, or omitBetas dropping OAuth, do not.
  testJevRouterBillingGuard = {
    expr = map evaluates [
      [ ]
      [ { systemd.user.services.jev-router.Service.Environment = [ "ANTHROPIC_API_KEY=sk-test" ]; } ]
      [ { d.agentHost.jevRouter.secretEnv.ANTHROPIC_API_KEY = "op://Dev/x/credential"; } ]
      [ { d.claudeHarness.settings.extra.env.ANTHROPIC_AUTH_TOKEN = "x"; } ]
      [ { d.claudeHarness.settings.extra.apiKeyHelper = "/bin/echo"; } ]
      [ { home.sessionVariables.ANTHROPIC_API_KEY = "x"; } ]
      [ { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.heavy.keyEnv = "ANTHROPIC_API_KEY"; } ]
      [ { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.medium.clientAuth = false; } ]
      [
        { d.agentHost.jevRouter.extraConfig.surfaces.anthropic.light.omitBetas = [ "oauth-2025-04-20" ]; }
      ]
    ];
    expected = [
      true
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
