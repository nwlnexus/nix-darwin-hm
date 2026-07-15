# home/cli/claude/default.nix
{
  pkgs,
  lib,
  config,
  ...
}:
{
  # /brain slash command (consult + ingest the second-brain wiki).
  home.file.".claude/commands/brain.md".source = ./commands/brain.md;

  # Capture-worker env (the worker reads these; hooks fall back to defaults).
  home.sessionVariables = {
    SECOND_BRAIN_PATH = "${config.home.homeDirectory}/Documents/Obsidian Vault/brain";
    MNEMOSYNE_OLLAMA_URL = "http://ai-hub.raptor-mimosa.ts.net:11434";
    MNEMOSYNE_MODEL = "qwen3.5:9b";
  };

  # mnemosyne is an `npm:@nwlnexus/mnemosyne` mise global (home/default.nix) —
  # same pattern as gitnexus/repomix, and for the same reason: it isn't in
  # nixpkgs. Credentials (moneta token + CF Access) are file-provisioned by
  # op-secrets (home/apps/1password.nix) rather than shell-sourced, since
  # hook commands run as children of the agent process, not a login shell —
  # see nwlnexus/mnemosyne#30. This replaces the old mem0ctl/flake apparatus
  # entirely (nix-darwin-hm#58/#61, nwlnexus/mnemosyne#33).
  #
  # `mnemosyne install-hooks` is itself idempotent (keyed replace-or-skip
  # merge into each agent's config, per its own design) — safe to rerun on
  # every activation. Resolved by absolute mise-shim path, not PATH lookup:
  # a mise global's only PATH entry is the shims dir, which the INTERACTIVE
  # shell profile adds — home-manager's activation script sources no shell
  # profile, so a bare `mnemosyne install-hooks` would fail with "command not
  # found" (the exact gitnexusSetup/repomix-pack footgun already documented
  # elsewhere in this repo: modules/repomix/repomix.nix).
  #
  # Confirmed live on a real switch: merely declaring a tool in
  # programs.mise.globalConfig.tools does NOT install it — nothing in this
  # repo runs `mise install` anywhere, so a newly-added global's shim simply
  # doesn't exist yet after activation (gitnexusSetup below has this same
  # latent gap; not fixed here, out of scope for this pass). Explicitly
  # install it first, via mise's own nix-store path (mise is a real nixpkgs
  # package from `programs.mise.enable`, unlike the npm-global tools it
  # manages, so this one call IS safe to resolve via PATH-free absolute
  # path without the shim dance). Idempotent/fast when already installed.
  home.activation.mnemosyneSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.mise}/bin/mise install npm:@nwlnexus/mnemosyne 2>&1 || true
    MNEMOSYNE_BIN="${config.home.homeDirectory}/.local/share/mise/shims/mnemosyne"
    if [ -x "$MNEMOSYNE_BIN" ]; then
      "$MNEMOSYNE_BIN" install-hooks || true
    fi
  '';

  # gitnexus ships its own installer; it is idempotent and non-interactive.
  # gitnexus is a mise global (npm:gitnexus, see home/default.nix), not a
  # nixpkgs package, so it has no nix store path and isn't on the activation
  # script's PATH — resolve it by absolute path instead.
  #
  # The SHIM, not `installs/npm-gitnexus/latest/bin/gitnexus`: that install path
  # is a `#!/usr/bin/env node` script, and `node` is itself a mise global that is
  # NOT on the activation script's PATH either — so the old path failed with
  # `env: node: No such file or directory` and, being `|| true`, failed silently
  # on every rebuild. The shim is the mise binary itself and resolves its own
  # node. (modules/repomix/repomix.nix resolves both mise globals the same way.)
  # Fail-soft: a fresh host may not have the mise global installed yet.
  home.activation.gitnexusSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    GITNEXUS_BIN="${config.home.homeDirectory}/.local/share/mise/shims/gitnexus"
    if [ -x "$GITNEXUS_BIN" ]; then
      "$GITNEXUS_BIN" setup -c claude || true
    fi
  '';
}
