# "Nothing personal" on a work-only host (olympus-sdk #691): dtlr-ai-agent-host as evaluated from the flake
# (d.workOnly, system/darwin/work-only.nix + home/work-only.nix). Nothing is built. The private-input half
# (the host evaluates and builds without the private olympus-sdk input) is tests/work-only-private-input.sh.
# A personal Mac (nwl-mstudio) is the control: the same probes must find the personal config there, so a probe
# that can never fire fails here instead of passing silently.
{ flake, lib }:
let
  user = "nwilliams-lucas";
  h = "/Users/${user}";
  workAccount = "dtlrinc.1password.com";

  sys = flake.darwinConfigurations.dtlr-ai-agent-host.config;
  hm = sys.home-manager.users.${user};
  ctl = flake.darwinConfigurations.nwl-mstudio.config.home-manager.users.${user};

  # Everything the home config writes, store hashes stripped, as one string.
  dump =
    c:
    builtins.toJSON (
      import ./lib/hm-snapshot.nix {
        inherit lib;
        hm = c;
      }
    );
  # Markers of the personal account, identities and infrastructure.
  personalMarkers = [
    "my.1password.com"
    "op://Dev/"
    "/.config/personal/1penv"
    "4689066+nwlucas@"
    "/.ssh/id_ed25519"
    "Obsidian Vault"
    "second-brain"
    "SECOND_BRAIN"
    "memory-gateway"
    "memory-capture"
    "raptor-mimosa.ts.net"
    "ssh.nwlnexus.net"
    "projects/personal/.env"
    "projects/personal/.op-connect"
  ];
  found = c: lib.filter (m: lib.hasInfix m (dump c)) personalMarkers;

  secrets = c: c.op-secrets.secrets;
  # Every string a secret carries (source, account, dest, token command) plus its template's text.
  secretText =
    c:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        _: s:
        builtins.toJSON (removeAttrs s [ "template" ])
        + (if (s.template or null) == null then "" else builtins.readFile s.template)
      ) (secrets c)
    );

  rc = c: lib.attrNames (lib.filterAttrs (n: a: a.enable && lib.hasInfix "-rc-" n) c.launchd.agents);
  files = c: lib.mapAttrsToList (_: f: f.target) (lib.filterAttrs (_: f: f.enable) c.home.file);
  gitConfig = c: c.xdg.configFile."git/config".text;
in
{
  testWorkOnlyIsOn = {
    expr = [
      sys.d.workOnly.enable
      hm.d.workOnly.enable
      ctl.d.workOnly.enable
    ];
    expected = [
      true
      true
      false
    ];
  };

  # op-secrets: only work-account secrets, with the work token file.
  testWorkOnlySecretsWorkAccountOnly = {
    expr = [
      (lib.attrNames (secrets hm))
      (lib.unique (lib.mapAttrsToList (_: s: s.account) (secrets hm)))
      (lib.unique (lib.mapAttrsToList (_: s: s.serviceAccountTokenCommand) (secrets hm)))
      hm.d.apps.onepassword.tokenFiles.personal
    ];
    expected = [
      [ "work-env" ]
      [ workAccount ]
      [ "cat ${h}/.config/work/1penv" ]
      null
    ];
  };
  # No secret source, template or token command names the personal account, vault or token file.
  testWorkOnlySecretsNoPersonalSource = {
    expr = map (m: lib.hasInfix m (secretText hm)) [
      "my.1password.com"
      "op://Dev/"
      "/.config/personal/"
      "projects/personal/"
    ];
    expected = [
      false
      false
      false
      false
    ];
  };
  testWorkOnlySecretsControl = {
    expr = map (n: (secrets ctl) ? ${n}) [
      "github-personal"
      "personal-env"
      "op-connect-env"
      "work-env"
    ];
    expected = [
      true
      true
      true
      true
    ];
  };

  # No memory-gateway client: module off, nothing wired, no secrets fetched, no hooks package.
  testWorkOnlyNoMemory = {
    expr = [
      hm.d.memory.enable
      (hm.home.activation ? memoryWire)
      (hm.home.activation ? memorySecrets)
      (lib.elem "memory-hooks" (map lib.getName hm.home.packages))
    ];
    expected = [
      false
      false
      false
      false
    ];
  };

  # No second-brain: no checkout, no pull agent, no /brain command, and no SECOND_BRAIN_PATH at all (so nothing
  # falls back to the personal Obsidian vault).
  testWorkOnlyNoSecondBrain = {
    expr = [
      hm.d.agentHost.secondBrain.enable
      (hm.launchd.agents ? second-brain-pull)
      (hm.home.activation ? secondBrainClone)
      (lib.elem "second-brain-sync" (map lib.getName hm.home.packages))
      (hm.home.sessionVariables ? SECOND_BRAIN_PATH)
      (lib.filter (lib.hasSuffix "commands/brain.md") (files hm))
    ];
    expected = [
      false
      false
      false
      false
      false
      [ ]
    ];
  };
  testWorkOnlySecondBrainControl = {
    expr = ctl.home.sessionVariables.SECOND_BRAIN_PATH;
    expected = "${h}/Documents/Obsidian Vault/brain";
  };

  # Claude harness: no autoMode and no telemetry from the private personal input; harness dirs are the work
  # account's only.
  testWorkOnlyHarness = {
    expr = [
      hm.d.claudeHarness.settings.autoModeFile
      hm.d.claudeHarness.settings.autoMode
      hm.d.claudeHarness.telemetry.file
      hm.d.claudeHarness.telemetry.env
      (hm.home.activation ? claudeTelemetry)
      hm.d.claudeHarness.dirs
    ];
    expected = [
      null
      null
      null
      { }
      false
      [ ".claude-work" ]
    ];
  };

  # Git: the work identity globally, signed with the work key, no personal include; ssh: no personal blocks.
  testWorkOnlyGitIdentity = {
    expr = [
      hm.programs.git.settings.user.email
      hm.programs.git.signing.key
      (map (i: i.condition) hm.programs.git.includes)
      (lib.hasInfix "4689066+nwlucas@" (gitConfig hm))
      (lib.hasInfix ''[url "git@github.com-work:"]'' (gitConfig hm))
    ];
    expected = [
      "59927973+nwilliams-lucas@users.noreply.github.com"
      "~/.ssh/gitlab-work-gl"
      [ ]
      false
      true
    ];
  };
  testWorkOnlySshNoPersonalHosts = {
    expr = map (m: lib.hasInfix m hm.home.file.".ssh/config".text) [
      "Host github.com\n"
      "id_ed25519"
      "nwlnexus.net"
      "raptor-mimosa.ts.net"
      "Host github.com-work"
    ];
    expected = [
      false
      false
      false
      false
      true
    ];
  };

  # Whole-config scan: no personal marker anywhere in what the home config writes; the control has them.
  testWorkOnlyNoPersonalMarkers = {
    expr = found hm;
    expected = [ ];
  };
  testWorkOnlyMarkersControl = {
    expr = lib.length (found ctl) > 5;
    expected = true;
  };
  testWorkOnlyNoPersonalTree = {
    expr = lib.filter (lib.hasInfix "/projects/personal/") (files hm);
    expected = [ ];
  };

  # The private personal input is not linked into /etc/nix/inputs.
  testWorkOnlyNoPrivateInputLink = {
    expr = sys.environment.etc."nix/inputs/olympus-sdk".enable;
    expected = false;
  };

  # Tailscale: the Homebrew formula, never the app cask.
  testWorkOnlyTailscaleFormula = {
    expr = [
      (lib.elem "tailscale-app" (map (c: c.name) sys.homebrew.casks))
      (lib.elem "tailscale" (map (b: b.name) sys.homebrew.brews))
    ];
    expected = [
      false
      true
    ];
  };

  # No atlas brew / olympus tap / obsidian cask on a work-only host; the control Mac keeps them.
  testWorkOnlyNoAtlasObsidian = {
    expr =
      let
        hb = sys.homebrew;
        ch = flake.darwinConfigurations.nwl-mstudio.config.homebrew;
        has = c: [
          (lib.elem "nwlnexus/olympus/atlas" (map (b: b.name) c.brews))
          (lib.elem "obsidian" (map (k: k.name) c.casks))
          (lib.hasInfix "nwlnexus/olympus" (
            c.extraConfig + lib.concatStringsSep "\n" (map (t: t.name) c.taps)
          ))
        ];
      in
      {
        workOnly = has hb;
        control = has ch;
      };
    expected = {
      workOnly = [
        false
        false
        false
      ];
      control = [
        true
        true
        true
      ];
    };
  };

  # Runs like ai-agent-host: Remote Control launchd agents for the one work account, server-like power settings.
  testWorkOnlyRemoteControl = {
    expr = [
      (rc hm)
      hm.d.agentHost.defaultAccount
      hm.launchd.agents.claude-rc-work.config.WorkingDirectory
    ];
    expected = [
      [
        "claude-rc-work"
        "codex-rc-work"
      ]
      "work"
      "${h}/projects/work"
    ];
  };
  testWorkOnlyServerPower = {
    expr = [
      sys.power.sleep.computer
      sys.power.restartAfterPowerFailure
      sys.networking.wakeOnLan.enable
    ];
    expected = [
      "never"
      true
      true
    ];
  };
}
