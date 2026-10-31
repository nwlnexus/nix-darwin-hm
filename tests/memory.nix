# Claude Code memory-gateway client (home/cli/memory). Disabled by default; the enabled variants are evaluated
# through extendModules on the agent host (eval only, nothing is built or activated).
#
# ai-agent-host itself enables the module (tailnet, personal only since #675, no ~/.claude: olympus-sdk #559), so the
# generic option tests start from `base`, the host with that choice undone, and testAgentHostEnablesMemory
# pins what the host really sets.
{ flake, lib }:
let
  deployed = flake.homeConfigurations."nwilliams-lucas@ai-agent-host";
  base = deployed.extendModules {
    modules = [
      {
        d.memory = {
          enable = lib.mkForce false;
          accounts.default.enable = lib.mkForce true;
        };
      }
    ];
  };
  on = lib.mkOverride 40 true;
  h = "/home/nwilliams-lucas";
  with' =
    d:
    (base.extendModules {
      modules = [
        {
          # Beat the host's own settings (mode, fallback) with a stronger priority.
          d.memory = {
            enable = on;
          }
          // lib.mapAttrs (_: lib.mkOverride 40) d;
        }
      ];
    }).config;
  tailnet = with' { };
  public = with' { mode = "public"; };
  fallback = with' { fallback = true; };

  target = c: name: lib.findFirst (t: t.name == name) null c.d.memory.wiring.targets;
  hooksOf = t: lib.mapAttrs (_: g: lib.head g.hooks) t.hooks;
  personal = target tailnet "personal";
  default' = target tailnet "default";
  strip =
    s:
    lib.concatStringsSep "" (
      map (x: if lib.isList x then "STORE-" else x) (builtins.split "/nix/store/[a-z0-9]{32}-" s)
    );
  stripEnv = strip;
  short = builtins.substring 0 8 flake.inputs.olympus-sdk.rev;
in
{
  # What hosts/linux/ai-agent-host.nix really sets: tailnet only, no fallback, ~/.claude left unwired, and since
  # olympus-sdk #675 the work account unwired (no target, so memory-wire removes its entries; no key fetched).
  testAgentHostEnablesMemory = {
    expr =
      let
        m = deployed.config.d.memory;
      in
      [
        m.enable
        m.mode
        m.fallback
        (map (t: t.name) m.wiring.targets)
        (map (s: s.ref) m.secrets)
        (deployed.config.home.activation ? memoryWire)
        (deployed.config.home.activation ? memorySecrets)
      ];
    expected = [
      true
      "tailnet"
      false
      [ "personal" ]
      [ "op://Dev/memory-gateway-keys/ai-agent-host-personal" ]
      true
      true
    ];
  };
  # #675/#693: there is no work account on this host (personal-only); its settings.json and .claude.json were
  # wired before, so they must not be in the spec
  # (memory-wire apply then removes the entries from the files its manifest recorded), and nothing in the
  # personal account's wiring may point at the work key or config dir.
  testAgentHostWorkAccountUnwired = {
    expr =
      let
        m = deployed.config.d.memory;
        spec = builtins.toJSON m.wiring;
      in
      [
        (m.accounts ? work)
        (lib.hasInfix ".claude-work" spec)
        (lib.hasInfix "gateway-key-work" spec)
        (lib.any (s: lib.hasInfix "work" s.dest) m.secrets)
        (lib.hasInfix "memory-wire apply" deployed.config.home.activation.memoryWire.data)
      ];
    expected = [
      false
      false
      false
      false
      true
    ];
  };
  # #675: the default route table: personal projects go to the gateway, work projects nowhere.
  testAgentHostRoutes = {
    expr = builtins.fromJSON deployed.config.d.memory.routeTables.personal;
    expected = {
      v = 1;
      routes = [
        {
          root = "${h}/projects/personal";
          backend = "gateway";
        }
        {
          root = "${h}/projects/work";
          backend = "none";
        }
      ];
    };
  };
  # Merging changes nothing: no option set, no activation step, no secret.
  testDisabledByDefault = {
    expr = [
      base.config.d.memory.enable
      (base.config.home.activation ? memoryWire)
      (base.config.home.activation ? memorySecrets)
    ];
    expected = [
      false
      false
      false
    ];
  };
  testCleanupOnlyWhenAskedAndDisabled = {
    expr =
      let
        c = (base.extendModules { modules = [ { d.memory.cleanup = true; } ]; }).config;
      in
      [
        (c.home.activation ? memoryWire)
        (lib.hasInfix "memory-wire remove" c.home.activation.memoryWire.data)
        (c.home.activation ? memorySecrets)
      ];
    expected = [
      true
      true
      false
    ];
  };
  testDefaultAccountsFollowTheHostsClaudeDirs = {
    expr = lib.sort lib.lessThan (map (t: t.settings) tailnet.d.memory.wiring.targets);
    expected = [
      "${h}/.claude-personal/settings.json"
      "${h}/.claude/settings.json"
    ];
  };
  # Claude keeps the default account's MCP config at ~/.claude.json, the others inside their dir.
  testMcpFileLocations = {
    expr = map (n: (target tailnet n).mcp) [
      "default"
      "personal"
    ];
    expected = [
      "${h}/.claude.json"
      "${h}/.claude-personal/.claude.json"
    ];
  };
  # Design 11: exactly these four events, with these matchers, timeouts and async flags, plus (#675, with a route
  # table) the PreToolUse guard on the memory MCP tools.
  testHookShape = {
    expr =
      let
        g = personal.hooks;
        hk = hooksOf personal;
      in
      {
        events = lib.sort lib.lessThan (lib.attrNames g);
        matchers = lib.mapAttrs (_: x: x.matcher or null) g;
        timeouts = lib.mapAttrs (_: x: x.timeout) hk;
        async = lib.mapAttrs (_: x: x.async or false) hk;
        types = lib.unique (lib.mapAttrsToList (_: x: x.type) hk);
      };
    expected = {
      events = [
        "PreCompact"
        "PreToolUse"
        "SessionEnd"
        "SessionStart"
        "Stop"
      ];
      matchers = {
        SessionStart = "startup|resume|clear|compact|fork";
        Stop = null;
        PreCompact = "manual|auto";
        SessionEnd = null;
        PreToolUse = "mcp__memory__.*";
      };
      timeouts = {
        SessionStart = 8;
        Stop = 60;
        PreCompact = 15;
        SessionEnd = 10;
        PreToolUse = 10;
      };
      async = {
        SessionStart = false;
        Stop = true;
        PreCompact = false;
        SessionEnd = false;
        PreToolUse = false;
      };
      types = [ "command" ];
    };
  };
  testHookCommandsRunTheRightScripts = {
    expr = lib.mapAttrs (
      _: x: lib.last (lib.splitString "/" (lib.last (lib.splitString " " x.command)))
    ) (hooksOf personal);
    expected = {
      SessionStart = "memory-session-start";
      Stop = "memory-capture";
      PreCompact = "memory-capture";
      SessionEnd = "memory-capture";
      PreToolUse = "memory-mcp-guard";
    };
  };
  testTailnetCommandEnvironment = {
    expr = stripEnv (hooksOf personal).Stop.command;
    expected = "MEMORY_GATEWAY_URL=http://memory.raptor-mimosa.ts.net MEMORY_KEY_FILE=${h}/.config/memory/gateway-key-personal MEMORY_ROUTES_FILE=STORE-memory-routes.json MEMORY_SHARE_DIR=STORE-memory-hooks-0-unstable-${short}/share/memory PATH=STORE-memory-hooks-path/bin:$PATH STORE-memory-hooks-0-unstable-${short}/bin/memory-capture";
  };
  # The default account keeps the default key path, so no MEMORY_KEY_FILE (design 11).
  testDefaultAccountOmitsKeyFile = {
    expr = lib.hasInfix "MEMORY_KEY_FILE" (hooksOf default').Stop.command;
    expected = false;
  };
  testTailnetHasNoAccessFilesOrMode = {
    expr = map (s: lib.hasInfix s (hooksOf personal).SessionStart.command) [
      "MEMORY_MODE"
      "MEMORY_ACCESS_CLIENT"
      "MEMORY_GATEWAY_URL_FALLBACK"
    ];
    expected = [
      false
      false
      false
    ];
  };
  testMcpServerTailnet = {
    expr = {
      inherit (personal.mcpServer) type url;
      helper = stripEnv personal.mcpServer.headersHelper;
    };
    expected = {
      type = "http";
      url = "http://memory.raptor-mimosa.ts.net/mcp";
      helper = "MEMORY_KEY_FILE=${h}/.config/memory/gateway-key-personal MEMORY_ROUTES_FILE=STORE-memory-routes.json PATH=STORE-memory-hooks-path/bin:$PATH STORE-memory-hooks-0-unstable-${short}/bin/memory-mcp-headers";
    };
  };
  testPublicMode = {
    expr =
      let
        t = target public "personal";
        c = (hooksOf t).SessionEnd.command;
      in
      [
        t.mcpServer.url
        (lib.hasPrefix "MEMORY_MODE=public MEMORY_GATEWAY_URL=https://memory.nwlnexus.io " c)
        (lib.hasInfix "MEMORY_ACCESS_CLIENT_ID_FILE=${h}/.config/memory/cf-access-client-id MEMORY_ACCESS_CLIENT_SECRET_FILE=${h}/.config/memory/cf-access-client-secret" c)
        (lib.hasInfix "MEMORY_GATEWAY_URL_FALLBACK" c)
        (lib.hasPrefix "MEMORY_MODE=public MEMORY_KEY_FILE=${h}/.config/memory/gateway-key-personal MEMORY_ACCESS_CLIENT_ID_FILE=" t.mcpServer.headersHelper)
      ];
    expected = [
      "https://memory.nwlnexus.io/mcp"
      true
      true
      false
      true
    ];
  };
  # Fallback is hooks-only: the MCP entry cannot fail over and stays on the tailnet URL.
  testFallbackMode = {
    expr =
      let
        t = target fallback "personal";
        c = (hooksOf t).Stop.command;
      in
      [
        t.mcpServer.url
        (lib.hasInfix "MEMORY_GATEWAY_URL=http://memory.raptor-mimosa.ts.net MEMORY_GATEWAY_URL_FALLBACK=https://memory.nwlnexus.io " c)
        (lib.hasInfix "MEMORY_ACCESS_CLIENT_ID_FILE" c)
        (lib.hasInfix "MEMORY_ACCESS_CLIENT" t.mcpServer.headersHelper)
      ];
    expected = [
      "http://memory.raptor-mimosa.ts.net/mcp"
      true
      true
      false
    ];
  };
  # The Access files exist only when mode = public or fallback = true.
  testSecretsPerMode = {
    expr = map (c: map (s: s.name) c.d.memory.secrets) [
      tailnet
      public
      fallback
    ];
    expected =
      let
        keys = [
          "memory-key-default"
          "memory-key-personal"
        ];
        access = [
          "memory-access-client-id"
          "memory-access-client-secret"
        ];
      in
      [
        keys
        (keys ++ access)
        (keys ++ access)
      ];
  };
  testSecretReferences = {
    expr = map (s: [
      s.ref
      s.dest
    ]) public.d.memory.secrets;
    expected = [
      [
        "op://Dev/memory-gateway-keys/ai-agent-host-default"
        "${h}/.config/memory/gateway-key"
      ]
      [
        "op://Dev/memory-gateway-keys/ai-agent-host-personal"
        "${h}/.config/memory/gateway-key-personal"
      ]
      [
        "op://Dev/memory-access-tokens/ai-agent-host-id"
        "${h}/.config/memory/cf-access-client-id"
      ]
      [
        "op://Dev/memory-access-tokens/ai-agent-host-secret"
        "${h}/.config/memory/cf-access-client-secret"
      ]
    ];
  };
  # Same escape hatch as op-secrets, and the fetch is fail-soft whatever the item state.
  testExcludeSecretsAndFailSoft = {
    expr =
      let
        c =
          (base.extendModules {
            modules = [
              {
                d.memory.enable = on;
                d.apps.onepassword.excludeSecrets = [ "memory-key-personal" ];
              }
            ];
          }).config;
        act = c.home.activation.memorySecrets.data;
      in
      [
        (map (s: s.name) c.d.memory.secrets)
        (lib.hasInfix "gateway-key-personal" act)
        (lib.hasInfix "|| true" act)
        (lib.hasInfix "--token-file ${h}/.config/personal/1penv" act)
      ];
    expected = [
      [ "memory-key-default" ]
      false
      true
      true
    ];
  };
  testManageSecretsOff = {
    expr = (with' { manageSecrets = false; }).home.activation ? memorySecrets;
    expected = false;
  };
  # Neither step may fail a switch, and the wiring step uses the recorded-manifest scheme.
  testWireActivation = {
    expr =
      let
        d = tailnet.home.activation.memoryWire.data;
      in
      [
        (lib.hasInfix "memory-wire apply --spec " d)
        (lib.hasInfix "--manifest ${h}/.local/state/memory-nix/wired.json" d)
        (lib.hasInfix "|| true" d)
      ];
    expected = [
      true
      true
      true
    ];
  };
  testSourceRevisionRecorded = {
    expr = tailnet.d.memory.package.passthru.rev == flake.inputs.olympus-sdk.rev;
    expected = true;
  };
  # Darwin hosts have no hostname specialArg: the host name must be given explicitly.
  testDarwinNeedsHost = {
    expr =
      let
        sys =
          (flake.darwinConfigurations.data-hub.extendModules {
            modules = [ { home-manager.users.nwilliams-lucas.d.memory.enable = true; } ];
          }).config;
      in
      map (a: a.message) (lib.filter (a: !a.assertion) sys.assertions);
    expected = [
      "nwilliams-lucas profile: d.memory.host must be set on this host (its 1Password field names are <host>-<account>)."
    ];
  };
  testDarwinDefaultAccountOnly = {
    expr =
      let
        hm =
          (flake.darwinConfigurations.NWL-MMINI.extendModules {
            modules = [
              {
                home-manager.users.nwilliams-lucas.d.memory = {
                  enable = true;
                  host = "NWL-MMINI";
                  mode = "public";
                };
              }
            ];
          }).config.home-manager.users.nwilliams-lucas;
        t = lib.head hm.d.memory.wiring.targets;
      in
      [
        (map (x: x.name) hm.d.memory.wiring.targets)
        t.settings
        t.mcp
        (map (s: s.ref) hm.d.memory.secrets)
      ];
    expected = [
      [ "default" ]
      "/Users/nwilliams-lucas/.claude/settings.json"
      "/Users/nwilliams-lucas/.claude.json"
      [
        "op://Dev/memory-gateway-keys/NWL-MMINI-default"
        "op://Dev/memory-access-tokens/NWL-MMINI-id"
        "op://Dev/memory-access-tokens/NWL-MMINI-secret"
      ]
    ];
  };
  # #675: `routes = null` is the route-less behaviour: no table, no guard, the same commands as before.
  testRoutesNull = {
    expr =
      let
        c = with' { routes = null; };
        t = target c "personal";
      in
      [
        c.d.memory.routeTables.personal
        (lib.attrNames t.hooks)
        (lib.hasInfix "MEMORY_ROUTES_FILE" (builtins.toJSON t))
      ];
    expected = [
      null
      [
        "PreCompact"
        "SessionEnd"
        "SessionStart"
        "Stop"
      ]
      false
    ];
  };
  # #675: every command of an account reads the same table: the four hooks, the guard and the headersHelper.
  testRoutesEverywhere = {
    expr = (lib.mapAttrs (_: x: lib.hasInfix "MEMORY_ROUTES_FILE=" x.command) (hooksOf personal)) // {
      helper = lib.hasInfix "MEMORY_ROUTES_FILE=" personal.mcpServer.headersHelper;
    };
    expected = {
      SessionStart = true;
      Stop = true;
      PreCompact = true;
      SessionEnd = true;
      PreToolUse = true;
      helper = true;
    };
  };
  # #675: an account can carry its own table; the others keep the global one.
  testRoutesPerAccount = {
    expr =
      let
        c =
          (base.extendModules {
            modules = [
              {
                d.memory.enable = on;
                d.memory.accounts.personal.routes = [
                  {
                    root = "/srv/p";
                    backend = "gateway";
                  }
                ];
              }
            ];
          }).config;
      in
      [
        (builtins.fromJSON c.d.memory.routeTables.personal).routes
        (map (r: r.root) (builtins.fromJSON c.d.memory.routeTables.default).routes)
      ];
    expected = [
      [
        {
          root = "/srv/p";
          backend = "gateway";
        }
      ]
      [
        "${h}/projects/personal"
        "${h}/projects/work"
      ]
    ];
  };
  testRoutesBackendIsChecked = {
    expr =
      (builtins.tryEval (
        builtins.toJSON
          (with' {
            routes = [
              {
                root = "/x";
                backend = "work-memory";
              }
            ];
          }).d.memory.routeTables
      )).success;
    expected = false;
  };
  # #675: the Macs that enable the module (one ~/.claude for CLI and Desktop Code sessions alike) route
  # ~/projects/work to none; the work Mac stays off.
  testDarwinHostsRoutes = {
    expr =
      let
        hm = n: flake.darwinConfigurations.${n}.config.home-manager.users.nwilliams-lucas.d.memory;
        mac = n: {
          enable = (hm n).enable;
          table = builtins.fromJSON (hm n).routeTables.default;
          guard = (lib.head (hm n).wiring.targets).hooks ? PreToolUse;
        };
      in
      [
        (mac "NWL-MBM2")
        (mac "NWL-MMINI")
        (hm "DTLR-NWLMMINI").enable
      ];
    expected =
      let
        mac = {
          enable = true;
          guard = true;
          table = {
            v = 1;
            routes = [
              {
                root = "/Users/nwilliams-lucas/projects/personal";
                backend = "gateway";
              }
              {
                root = "/Users/nwilliams-lucas/projects/work";
                backend = "none";
              }
            ];
          };
        };
      in
      [
        mac
        mac
        false
      ];
  };
}
