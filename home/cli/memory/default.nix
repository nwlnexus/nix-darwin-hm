# Claude Code <-> memory gateway wiring (olympus-sdk epic #444, task H5 of #452; design
# docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md sections 5.6, 7.1 and 11).
#
# For every Claude config dir this module
#   - installs the capture/recall hooks (packages/memory-hooks, ./package.nix) into the nix store,
#   - merges the SessionStart / Stop / PreCompact / SessionEnd hook entries into <dir>/settings.json and the
#     `memory` MCP server (with a `headersHelper`) into the account's .claude.json, with jq, touching nothing
#     else (./wire.sh: Claude Code owns and rewrites those files, so they are never replaced from nix),
#   - writes the gateway key (and, for `public` mode or the hook fallback, the Cloudflare Access service token)
#     to 0600 files under ~/.config/memory from 1Password at activation (./fetch-secrets.sh).
#
# Off by default: with `d.memory.enable = false` nothing is evaluated or installed. See AGENTS.md ("Memory
# gateway client") for how to enable it on a host.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}@args:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    concatStringsSep
    optional
    optionals
    ;

  cfg = config.d.memory;
  home = config.home.homeDirectory;
  esc = lib.escapeShellArg;

  # Both are optional: the agent-host and 1Password modules are not imported on every platform.
  agentHost = config.d.agentHost or { enable = false; };
  onepassword = config.d.apps.onepassword or { };

  defaultKeyFile = "${home}/.config/memory/gateway-key";
  needsAccess = cfg.mode == "public" || cfg.fallback;
  url = lib.removeSuffix "/" (if cfg.mode == "public" then cfg.publicUrl else cfg.tailnetUrl);

  accounts = lib.filterAttrs (_: a: a.enable) cfg.accounts;
  accountNames = lib.attrNames accounts;

  # Tools the scripts call (README of packages/memory-hooks). Put on PATH by the hook command line itself, not
  # by a wrapper: the scripts find their own directory through $0.
  runtimePath = pkgs.buildEnv {
    name = "memory-hooks-path";
    paths = [
      pkgs.jq
      pkgs.curl
      pkgs.gawk
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gitMinimal
    ]
    ++ optional (pkgs ? hostname) pkgs.hostname
    ++ optional pkgs.stdenv.isLinux pkgs.util-linux;
    pathsToLink = [ "/bin" ];
  };
  pathPrefix = "PATH=${runtimePath}/bin:$PATH";

  accessEnv = [
    "MEMORY_ACCESS_CLIENT_ID_FILE=${esc cfg.access.idFile}"
    "MEMORY_ACCESS_CLIENT_SECRET_FILE=${esc cfg.access.secretFile}"
  ];

  hookCommand =
    acct: script:
    concatStringsSep " " (
      optional (cfg.mode == "public") "MEMORY_MODE=public"
      ++ [ "MEMORY_GATEWAY_URL=${esc url}" ]
      ++ optional (
        cfg.mode == "tailnet" && cfg.fallback
      ) "MEMORY_GATEWAY_URL_FALLBACK=${esc cfg.publicUrl}"
      ++ optional (acct.keyFile != defaultKeyFile) "MEMORY_KEY_FILE=${esc acct.keyFile}"
      ++ optionals needsAccess accessEnv
      ++ [
        "MEMORY_SHARE_DIR=${cfg.package}/share/memory"
        pathPrefix
        "${cfg.package}/bin/${script}"
      ]
    );

  hookGroup =
    {
      matcher ? null,
      timeout,
      async ? false,
      command,
    }:
    {
      hooks = [
        (
          {
            type = "command";
            inherit timeout command;
          }
          // lib.optionalAttrs async { async = true; }
        )
      ];
    }
    // lib.optionalAttrs (matcher != null) { inherit matcher; };

  # Exactly the entries of design section 11.
  hooksFor = acct: {
    SessionStart = hookGroup {
      matcher = "startup|resume|clear|compact|fork";
      timeout = 8;
      command = hookCommand acct "memory-session-start";
    };
    Stop = hookGroup {
      timeout = 60;
      async = true;
      command = hookCommand acct "memory-capture";
    };
    PreCompact = hookGroup {
      matcher = "manual|auto";
      timeout = 15;
      command = hookCommand acct "memory-capture";
    };
    SessionEnd = hookGroup {
      timeout = 10;
      command = hookCommand acct "memory-capture";
    };
  };

  mcpServerFor = acct: {
    type = "http";
    url = "${url}/mcp";
    headersHelper = concatStringsSep " " (
      optional (cfg.mode == "public") "MEMORY_MODE=public"
      ++ [ "MEMORY_KEY_FILE=${esc acct.keyFile}" ]
      ++ optionals (cfg.mode == "public") accessEnv
      ++ [
        pathPrefix
        "${cfg.package}/bin/memory-mcp-headers"
      ]
    );
  };

  wiring = {
    targets = map (n: {
      name = n;
      settings = accounts.${n}.settingsFile;
      mcp = accounts.${n}.mcpFile;
      hooks = hooksFor accounts.${n};
      mcpServer = mcpServerFor accounts.${n};
    }) accountNames;
  };
  spec = pkgs.writeText "memory-wire-spec.json" (builtins.toJSON wiring);

  wire = pkgs.writeShellApplication {
    name = "memory-wire";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./wire.sh;
  };
  fetchSecrets = pkgs.writeShellApplication {
    name = "memory-fetch-secrets";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./fetch-secrets.sh;
  };

  manifest = "${config.xdg.stateHome}/memory-nix/wired.json";

  # 1Password reference of one account's key; @host@ and @account@ are substituted.
  fill = acctName: s: lib.replaceStrings [ "@host@" "@account@" ] [ (toString cfg.host) acctName ] s;
  keyRef = n: fill n (if accounts.${n}.keyItem != null then accounts.${n}.keyItem else cfg.keyItem);

  secretDefs =
    map (n: {
      name = "memory-key-${n}";
      ref = keyRef n;
      dest = accounts.${n}.keyFile;
    }) accountNames
    ++ optionals needsAccess [
      {
        name = "memory-access-client-id";
        ref = fill "" cfg.access.idItem;
        dest = cfg.access.idFile;
      }
      {
        name = "memory-access-client-secret";
        ref = fill "" cfg.access.secretItem;
        dest = cfg.access.secretFile;
      }
    ];
  # Same escape hatch as op-secrets: a host whose 1Password account cannot read an item lists its name.
  wantedSecrets = lib.filter (s: !(lib.elem s.name (onepassword.excludeSecrets or [ ]))) secretDefs;

  fetchArgs = concatStringsSep " " (
    [
      "--op ${pkgs._1password-cli}/bin/op"
      "--account ${esc cfg.opAccount}"
    ]
    ++ optional (cfg.opTokenFile != null) "--token-file ${esc cfg.opTokenFile}"
    ++ [ "--" ]
    ++ lib.concatMap (s: [
      (esc s.ref)
      (esc s.dest)
    ]) wantedSecrets
  );

  accountModule =
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Wire this Claude config dir. Turn off for an account that never runs here.";
        };
        configDir = mkOption {
          type = types.str;
          default = if name == "default" then "${home}/.claude" else "${home}/.claude-${name}";
          defaultText = lib.literalMD "`~/.claude` for `default`, `~/.claude-<name>` otherwise";
          description = "Claude config dir (what CLAUDE_CONFIG_DIR points at).";
        };
        settingsFile = mkOption {
          type = types.str;
          default = "${config.configDir}/settings.json";
          defaultText = lib.literalMD "`<configDir>/settings.json`";
          description = "File the hook entries are merged into.";
        };
        mcpFile = mkOption {
          type = types.str;
          default =
            if config.configDir == "${home}/.claude" then
              "${home}/.claude.json"
            else
              "${config.configDir}/.claude.json";
          defaultText = lib.literalMD "`~/.claude.json` for `~/.claude`, `<configDir>/.claude.json` otherwise";
          description = "File the `memory` MCP server is merged into (Claude Code keeps it beside the dir for ~/.claude).";
        };
        keyFile = mkOption {
          type = types.str;
          default =
            if name == "default" then defaultKeyFile else "${home}/.config/memory/gateway-key-${name}";
          defaultText = lib.literalMD "`~/.config/memory/gateway-key` for `default`, `gateway-key-<name>` otherwise";
          description = "Where this account's gateway key is written (0600) and read by the hooks and headersHelper.";
        };
        keyItem = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "1Password reference for this account's key; null uses `d.memory.keyItem`.";
        };
      };
    };

  defaultAccounts = {
    default = { };
  }
  // lib.mapAttrs (_: _: { }) (lib.optionalAttrs (agentHost.enable or false) agentHost.accounts);
in
{
  options.d.memory = {
    enable = mkEnableOption "the Claude Code memory-gateway client (MCP server + capture hooks)";

    mode = mkOption {
      type = types.enum [
        "tailnet"
        "public"
      ];
      default = "tailnet";
      description = ''
        `tailnet`: hooks and MCP talk to `tailnetUrl` with the gateway key only. `public`: they talk to
        `publicUrl` with the key plus a Cloudflare Access service token (machines off the tailnet).
      '';
    };

    tailnetUrl = mkOption {
      type = types.str;
      default = "http://memory.raptor-mimosa.ts.net";
      description = "Gateway URL on the tailnet (the Host check requires this hostname).";
    };

    publicUrl = mkOption {
      type = types.str;
      default = "https://memory.nwlnexus.io";
      description = "Public gateway URL (behind Cloudflare Access).";
    };

    fallback = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Tailnet mode only: give the hooks `MEMORY_GATEWAY_URL_FALLBACK=publicUrl`, tried when the tailnet route
        cannot connect, and install the two Access files. The MCP entry cannot fail over and stays on the
        tailnet URL.
      '';
    };

    host = mkOption {
      type = types.nullOr types.str;
      # `hostname` is a specialArg on the standalone Linux hosts only (a defaulted formal is not honoured here).
      default = args.hostname or null;
      defaultText = lib.literalMD "the flake host name on Linux agent hosts, otherwise unset";
      description = ''
        Host name used in the 1Password field names (`<host>-<account>`, `<host>-id`, `<host>-secret`) and
        the `memory-admin client create` client names. Set it on nix-darwin hosts.
      '';
    };

    accounts = mkOption {
      type = types.attrsOf (types.submodule accountModule);
      default = defaultAccounts;
      defaultText = lib.literalMD ''
        `default` (`~/.claude`) plus one entry per `d.agentHost.accounts` (`~/.claude-<name>`)
      '';
      description = ''
        Claude config dirs to wire. The attribute name is the account name in the 1Password field and the
        key file name (`default` keeps `gateway-key`; others get `gateway-key-<name>`).
      '';
    };

    keyItem = mkOption {
      type = types.str;
      default = "op://Dev/memory-gateway-keys/@host@-@account@";
      description = ''
        1Password reference of an account's gateway key: one field per host account in the
        `memory-gateway-keys` item (`@host@` and `@account@` are substituted). Mint the keys with
        `memory-admin client create`.
      '';
    };

    access = {
      idItem = mkOption {
        type = types.str;
        default = "op://Dev/memory-access-tokens/@host@-id";
        description = "1Password reference of this host's Access service token id.";
      };
      secretItem = mkOption {
        type = types.str;
        default = "op://Dev/memory-access-tokens/@host@-secret";
        description = "1Password reference of this host's Access service token secret.";
      };
      idFile = mkOption {
        type = types.str;
        default = "${home}/.config/memory/cf-access-client-id";
        description = "Where the token id is written (0600). Used when mode is public or fallback is on.";
      };
      secretFile = mkOption {
        type = types.str;
        default = "${home}/.config/memory/cf-access-client-secret";
        description = "Where the token secret is written (0600). Used when mode is public or fallback is on.";
      };
    };

    manageSecrets = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Write the key and Access files from 1Password at activation. A missing or unreadable item is a
        warning (the existing file is kept), never a failed switch. Off: provision the files yourself.
      '';
    };

    opAccount = mkOption {
      type = types.str;
      default = "my.1password.com";
      description = "1Password account holding the `Dev` vault.";
    };

    opTokenFile = mkOption {
      type = types.nullOr types.str;
      default = onepassword.tokenFiles.personal or null;
      defaultText = lib.literalMD "`d.apps.onepassword.tokenFiles.personal`";
      description = "Raw service-account token file for unattended activation (agent hosts).";
    };

    cleanup = mkOption {
      type = types.bool;
      default = false;
      description = ''
        With `enable = false`: remove the wiring this module installed earlier (hook entries, MCP server) from
        the files it recorded, then do nothing. Switch once with `enable = false; cleanup = true;` to
        uninstall. Key files under ~/.config/memory are left in place.
      '';
    };

    # What the activation steps are given, exposed for tests/memory.nix.
    wiring = mkOption {
      type = types.attrs;
      internal = true;
      readOnly = true;
      description = "The memory-wire spec (targets with hook entries and MCP server).";
    };
    secrets = mkOption {
      type = types.listOf types.attrs;
      internal = true;
      readOnly = true;
      description = "The 1Password references fetched at activation: name, ref, dest.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix {
        src = "${inputs.olympus-sdk}/packages/memory-hooks";
        rev = inputs.olympus-sdk.rev or null;
      };
      defaultText = lib.literalMD "`packages/memory-hooks` of the `olympus-sdk` flake input";
      description = "The memory-hooks package (bin/ and share/memory/, unchanged).";
    };
  };

  config = lib.mkMerge [
    {
      d.memory = {
        inherit wiring;
        secrets = wantedSecrets;
      };
    }
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = accountNames != [ ];
          message = "d.memory.accounts has no enabled account.";
        }
        {
          assertion =
            cfg.host != null
            || !(lib.any (s: lib.hasInfix "@host@" s) (
              [
                cfg.keyItem
                cfg.access.idItem
                cfg.access.secretItem
              ]
              ++ lib.concatMap (
                n: lib.optional (accounts.${n}.keyItem != null) accounts.${n}.keyItem
              ) accountNames
            ));
          message = "d.memory.host must be set on this host (its 1Password field names are <host>-<account>).";
        }
      ];

      warnings = optional (
        cfg.mode == "public" && cfg.fallback
      ) "d.memory.fallback has no effect in public mode (design 5.6: no hook fallback).";

      home.activation.memoryWire = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${wire}/bin/memory-wire apply --spec ${spec} --manifest ${esc manifest} || true
      '';

      home.activation.memorySecrets = mkIf cfg.manageSecrets (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${fetchSecrets}/bin/memory-fetch-secrets ${fetchArgs} || true
        ''
      );
    })

    (mkIf (!cfg.enable && cfg.cleanup) {
      home.activation.memoryWire = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${wire}/bin/memory-wire remove --manifest ${esc manifest} || true
      '';
    })
  ];
}
