# Per-account agent tooling on Linux agent hosts.
{ flake, lib }:
let
  hm = flake.homeConfigurations."nwilliams-lucas@ai-agent-host".config;
  svc = hm.systemd.user.services;
  h = "/home/nwilliams-lucas";
  pkgNames = map lib.getName hm.home.packages;
  # home-manager normalizes unit values to lists; read either form as one string.
  str = v: lib.concatStringsSep " " (map toString (lib.toList v));
in
{
  testRemoteControlUnits = {
    expr = lib.sort lib.lessThan (lib.attrNames (lib.filterAttrs (n: _: lib.hasInfix "-rc-" n) svc));
    expected = [
      "claude-rc-personal"
      "codex-rc-personal"
    ];
  };
  testClaudeWorkingDirectory = {
    expr = (str svc.claude-rc-personal.Service.WorkingDirectory);
    expected = "${h}/projects/personal";
  };
  testClaudeServerMode = {
    expr = lib.hasSuffix "/bin/claude-personal remote-control" (
      str svc.claude-rc-personal.Service.ExecStart
    );
    expected = true;
  };
  # Codex 0.159's foreground `remote-control` fails its socket-parent check;
  # the managed daemon (`start`/`stop`) works, so the unit drives that.
  testCodexDaemonManaged = {
    expr =
      let
        u = svc.codex-rc-personal.Service;
      in
      [
        (u.Type or null)
        (u.RemainAfterExit or false)
        (lib.hasSuffix "/bin/codex-personal remote-control start" (str (u.ExecStart or "")))
        (lib.hasSuffix "/bin/codex-personal remote-control stop" (str (u.ExecStop or "")))
        (u.Restart or null)
      ];
    expected = [
      "oneshot"
      true
      true
      true
      "on-failure"
    ];
  };
  testClaudeCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.claude-personal/.credentials.json" (
      str svc.claude-rc-personal.Service.ExecCondition
    );
    expected = true;
  };
  testCodexCondition = {
    expr = lib.hasSuffix "/bin/test -f ${h}/.codex-personal/auth.json" (
      str svc.codex-rc-personal.Service.ExecCondition
    );
    expected = true;
  };
  testRestartAndBoot = {
    expr = [
      (str svc.claude-rc-personal.Service.Restart)
      svc.claude-rc-personal.Install.WantedBy
    ];
    expected = [
      "always"
      [ "default.target" ]
    ];
  };
  testDefaultAccount = {
    expr = [
      hm.home.sessionVariables.CLAUDE_CONFIG_DIR
      hm.home.sessionVariables.CODEX_HOME
    ];
    expected = [
      "${h}/.claude-personal"
      "${h}/.codex-personal"
    ];
  };
  # The account follows $PWD at every prompt (after direnv), so nested repos
  # with their own .envrc keep the right account.
  testAccountPromptHook = {
    expr = map (x: lib.hasInfix x hm.programs.zsh.initContent) [
      "precmd_functions+=(_agent_host_account)"
      "${h}/projects/work/*) export CLAUDE_CONFIG_DIR=${h}/.claude-work CODEX_HOME=${h}/.codex-work ;;"
      "${h}/projects/personal/*) export CLAUDE_CONFIG_DIR=${h}/.claude-personal CODEX_HOME=${h}/.codex-personal ;;"
      "*) export CLAUDE_CONFIG_DIR=${h}/.claude-personal CODEX_HOME=${h}/.codex-personal ;;"
    ];
    expected = [
      true
      false
      true
      true
    ];
  };
  # The tree-level .envrc no longer carries the account (nearest-.envrc-only).
  testDirenvHooksCarryNoAccount = {
    expr = lib.hasInfix "CLAUDE_CONFIG_DIR" hm.home.file."direnv-hook-personal".text;
    expected = false;
  };
  # Second-brain wiki (olympus-sdk #562): a checkout path outside both project trees, set for every session,
  # an activation clone, and an hourly pull timer that can only fast-forward.
  testSecondBrainPath = {
    expr = hm.home.sessionVariables.SECOND_BRAIN_PATH;
    expected = "${h}/.local/share/second-brain";
  };
  testSecondBrainClone = {
    expr = lib.hasSuffix "second-brain-sync clone || true" (
      lib.removeSuffix "\n" hm.home.activation.secondBrainClone.data
    );
    expected = true;
  };
  testSecondBrainTimer = {
    expr =
      let
        t = hm.systemd.user.timers.second-brain-pull;
      in
      [
        (str t.Timer.OnCalendar)
        t.Timer.Persistent
        t.Install.WantedBy
        (lib.hasSuffix "/bin/second-brain-sync pull" (str svc.second-brain-pull.Service.ExecStart))
        (lib.elem "SECOND_BRAIN_PATH=${h}/.local/share/second-brain" svc.second-brain-pull.Service.Environment)
      ];
    expected = [
      "hourly"
      true
      [ "timers.target" ]
      true
      true
    ];
  };
  testBrainCommandLinked = {
    expr = hm.home.file ? ".claude-personal/commands/brain.md";
    expected = true;
  };
  testCommands = {
    expr = map (n: builtins.elem n pkgNames) [
      "claude-personal"
      "claude-work"
      "codex-personal"
      "codex-work"
      "agents"
    ];
    expected = [
      true
      false
      true
      false
      true
    ];
  };
  # Codex refuses to start when CODEX_HOME doesn't exist ("that path does not exist").
  testConfigDirsCreated = {
    expr =
      map (d: lib.hasInfix "install -d -m 0700 ${h}/${d}" (hm.home.activation.agentHostDirs.data or ""))
        [
          ".claude-personal"
          ".claude-work"
          ".codex-personal"
          ".codex-work"
        ];
    expected = [
      true
      false
      true
      false
    ];
  };

  # Personal-only (olympus-sdk#693, home/personal-only.nix): ai-agent-host carries no work account, tree, secret,
  # git include or ssh block. The memory route table still denies ~/projects/work (tests/memory.nix).
  testPersonalOnlyOn = {
    expr = [
      hm.d.personalOnly.enable
      hm.d.workOnly.enable
      hm.d.apps.onepassword.allowedAccounts
      hm.d.apps.onepassword.tokenFiles.work
    ];
    expected = [
      true
      false
      [ "my.1password.com" ]
      null
    ];
  };
  testPersonalOnlyNoWorkEnvrc = {
    expr = [
      hm.home.file."direnv-hook-work".enable
      hm.home.file."direnv-hook-personal".enable
      (lib.elem "${h}/projects/work/.envrc" (
        lib.mapAttrsToList (_: f: f.target) (lib.filterAttrs (_: f: f.enable) hm.home.file)
      ))
    ];
    expected = [
      false
      true
      false
    ];
  };
  testPersonalOnlyNoWorkSecrets = {
    expr =
      let
        secrets = hm.op-secrets.secrets;
        text = builtins.toJSON (lib.mapAttrs (_: s: removeAttrs s [ "template" ]) secrets);
      in
      [
        (secrets ? work-env)
        (lib.hasInfix "dtlrinc" text)
        (lib.hasInfix "projects/work" text)
      ];
    expected = [
      false
      false
      false
    ];
  };
  testPersonalOnlyNoWorkAgents = {
    expr = [
      (lib.filter (lib.hasInfix "work") (lib.attrNames svc))
      (lib.attrNames hm.d.agentHost.accounts)
      (lib.hasInfix "projects/work" hm.programs.zsh.initContent)
    ];
    expected = [
      [ ]
      [ "personal" ]
      false
    ];
  };
  testPersonalOnlyNoWorkGitSsh = {
    expr =
      let
        git = hm.xdg.configFile."git/config".text;
        ssh = hm.home.file.".ssh/config".text;
      in
      [
        (map (i: i.condition) hm.programs.git.includes)
        (lib.hasInfix "gitconfig-work" git)
        (lib.hasInfix "github.com-work" (git + ssh))
        (lib.hasInfix "gitlab-work.com" ssh)
        (lib.hasInfix "dtlronline" ssh)
        (lib.hasInfix "Host github.com\n" ssh)
      ];
    expected = [
      [ "gitdir:projects/personal/" ]
      false
      false
      false
      false
      true
    ];
  };

  # Other hosts are unchanged: personalOnly is off, the work tree and account are still there.
  testPersonalOnlyOffElsewhere = {
    expr =
      let
        mac = flake.darwinConfigurations.NWL-MMINI.config.home-manager.users.nwilliams-lucas;
        wk = flake.darwinConfigurations.dtlr-ai-agent-host.config.home-manager.users.nwilliams-lucas;
      in
      [
        mac.d.personalOnly.enable
        wk.d.personalOnly.enable
        mac.home.file."direnv-hook-work".enable
        (mac.op-secrets.secrets ? work-env)
        (map (i: i.condition) mac.programs.git.includes)
        (lib.hasInfix "Host github.com-work" mac.home.file.".ssh/config".text)
      ];
    expected = [
      false
      false
      true
      true
      [
        "gitdir:projects/work/"
        "hasconfig:remote.*.url:git@github.com-work/**"
        "hasconfig:remote.*.url:git@gitlab-work.com/**"
        "gitdir:projects/personal/"
      ]
      true
    ];
  };
  # The assertions (they abort evaluation of the activation package): none fails as deployed; mutually exclusive
  # with workOnly; no account rooted under the work tree; no work token file.
  testPersonalOnlyAssertions = {
    expr =
      let
        evaluates =
          mods:
          (builtins.tryEval (
            builtins.unsafeDiscardStringContext
              (flake.homeConfigurations."nwilliams-lucas@ai-agent-host".extendModules {
                modules = mods;
              }).config.home.activationPackage.drvPath
          )).success;
      in
      map evaluates [
        [ ]
        [ { d.workOnly.enable = true; } ]
        [ { d.agentHost.accounts.work.root = "${h}/projects/work"; } ]
        [ { d.apps.onepassword.tokenFiles.work = "${h}/.config/work/1penv"; } ]
      ];
    expected = [
      true
      false
      false
      false
    ];
  };
}
