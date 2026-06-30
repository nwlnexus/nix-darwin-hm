# home/cli/claude/default.nix
{ pkgs, lib, ... }:
let
  runtimeDeps = with pkgs; [ curl jq python3 uv gnugrep coreutils procps ];
  mem0ctlPkg = pkgs.stdenv.mkDerivation {
    pname = "mem0ctl";
    version = "1.1.0";
    src = ./.;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/mem0ctl" "$out/bin"
      cp ${./mem0ctl.sh}            "$out/share/mem0ctl/mem0ctl.sh"
      cp ${./mem0-recall-hook.sh}   "$out/share/mem0ctl/mem0-recall-hook.sh"
      cp ${./mem0_recall_format.py} "$out/share/mem0ctl/mem0_recall_format.py"
      cp -R ${./mem0-migrate}       "$out/share/mem0ctl/mem0-migrate"
      chmod +x "$out/share/mem0ctl/mem0ctl.sh" "$out/share/mem0ctl/mem0-recall-hook.sh"
      makeWrapper "$out/share/mem0ctl/mem0ctl.sh" "$out/bin/mem0ctl" \
        --prefix PATH : ${lib.makeBinPath runtimeDeps}
      runHook postInstall
    '';
  };
in
{
  home.packages = [ mem0ctlPkg ];

  # Declarative recall hook + its formatter sibling (store symlinks).
  home.file.".claude/hooks/mem0-recall-hook.sh".source =
    "${mem0ctlPkg}/share/mem0ctl/mem0-recall-hook.sh";
  home.file.".claude/hooks/mem0_recall_format.py".source =
    "${mem0ctlPkg}/share/mem0ctl/mem0_recall_format.py";

  # Imperative settings.json merge on every rebuild — fail-soft, no network.
  home.activation.mem0Enable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${lib.makeBinPath runtimeDeps}:$PATH" \
      "${mem0ctlPkg}/bin/mem0ctl" enable --no-verify || true
  '';
}
