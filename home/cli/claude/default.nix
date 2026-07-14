# home/cli/claude/default.nix
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  runtimeDeps = with pkgs; [
    curl
    jq
    python3
    uv
    gnugrep
    coreutils
    procps
  ];
  mem0ctlPkg = pkgs.stdenv.mkDerivation {
    pname = "mem0ctl";
    version = "1.3.0";
    src = ./.;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/mem0ctl" "$out/bin"
      cp ${./mem0ctl.sh}            "$out/share/mem0ctl/mem0ctl.sh"
      cp ${./moneta-recall-hook.sh}   "$out/share/mem0ctl/moneta-recall-hook.sh"
      cp ${./moneta_recall_format.py} "$out/share/mem0ctl/moneta_recall_format.py"
      cp ${./mem0-add.sh}           "$out/share/mem0ctl/mem0-add.sh"
      cp ${./mnemosyne-drain.sh}    "$out/share/mem0ctl/mnemosyne-drain.sh"
      cp ${./mnemosyne-enqueue.sh}  "$out/share/mem0ctl/mnemosyne-enqueue.sh"
      cp -R ${./mem0-migrate}       "$out/share/mem0ctl/mem0-migrate"
      chmod +x "$out/share/mem0ctl/mem0ctl.sh" "$out/share/mem0ctl/moneta-recall-hook.sh" \
               "$out/share/mem0ctl/mem0-add.sh" "$out/share/mem0ctl/mnemosyne-drain.sh" \
               "$out/share/mem0ctl/mnemosyne-enqueue.sh"
      makeWrapper "$out/share/mem0ctl/mem0ctl.sh" "$out/bin/mem0ctl" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
      # mem0-add.sh on PATH — the mnemosyne worker (spawnMem0Add) and the drain
      # replay both invoke it by name; ensure curl is available to it.
      makeWrapper "$out/share/mem0ctl/mem0-add.sh" "$out/bin/mem0-add.sh" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
      runHook postInstall
    '';
  };

  # The mnemosyne CLI now comes from the nix-built `mnemosyne` flake input
  # (no manual clone/build). Wrapped so `mem0-add.sh` is on PATH — the CLI's
  # spawnMem0Add execs it by name at runtime.
  mnemosynePkg = inputs.mnemosyne.packages.${pkgs.stdenv.hostPlatform.system}.default;
  mnemosyneBin = pkgs.symlinkJoin {
    name = "mnemosyne";
    paths = [ mnemosynePkg ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/mnemosyne" \
        --prefix PATH : ${lib.makeBinPath [ mem0ctlPkg ]} \
        --run 'if [ -f "$HOME/projects/personal/.env" ]; then set -a; . "$HOME/projects/personal/.env"; set +a; fi'
    '';
  };
in
{
  home.packages = [
    mem0ctlPkg
    mnemosyneBin
  ];

  # Declarative recall hook + formatter, and the mnemosyne capture hooks
  # (store symlinks). `mem0ctl enable` wires them into settings.json.
  home.file.".claude/hooks/moneta-recall-hook.sh".source =
    "${mem0ctlPkg}/share/mem0ctl/moneta-recall-hook.sh";
  home.file.".claude/hooks/moneta_recall_format.py".source =
    "${mem0ctlPkg}/share/mem0ctl/moneta_recall_format.py";
  home.file.".claude/hooks/mnemosyne-drain.sh".source =
    "${mem0ctlPkg}/share/mem0ctl/mnemosyne-drain.sh";
  home.file.".claude/hooks/mnemosyne-enqueue.sh".source =
    "${mem0ctlPkg}/share/mem0ctl/mnemosyne-enqueue.sh";

  # /brain slash command (consult + ingest the second-brain wiki).
  home.file.".claude/commands/brain.md".source = ./commands/brain.md;

  # Capture-worker env (the worker reads these; hooks fall back to defaults).
  home.sessionVariables = {
    SECOND_BRAIN_PATH = "${config.home.homeDirectory}/Documents/Obsidian Vault/brain";
    MNEMOSYNE_OLLAMA_URL = "http://ai-hub.raptor-mimosa.ts.net:11434";
    MNEMOSYNE_MODEL = "qwen3.5:9b";
  };

  # Imperative settings.json merge on every rebuild — fail-soft, no network.
  home.activation.mem0Enable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${lib.makeBinPath runtimeDeps}:$PATH" \
      "${mem0ctlPkg}/bin/mem0ctl" enable --no-verify || true
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
