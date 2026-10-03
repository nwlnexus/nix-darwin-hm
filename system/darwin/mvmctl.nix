# mvmctl (microVM CLI) from the pinned prebuilt GitHub release, laid out and
# signed the way upstream's install.sh does it. On macOS 26+ Apple Silicon the
# release uses the in-house HVF backend and needs no Homebrew deps (no libkrun,
# libkrunfw, libepoxy or virglrenderer). `mvmctl doctor` checks the host.
#
# Bump: change `version` + `hash`. Take the sha256 for
# mvmctl-aarch64-apple-darwin.tar.gz from the release's checksums-sha256.txt and
# convert it with `nix hash convert --hash-algo sha256 --to sri <hex>`.
{
  pkgs,
  lib,
  ...
}:

let
  version = "0.22.0";

  mvmctl = pkgs.stdenvNoCC.mkDerivation {
    pname = "mvmctl";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/tinylabscom/mvm/releases/download/v${version}/mvmctl-aarch64-apple-darwin.tar.gz";
      hash = "sha256-HyyAslOt0ow4VggOPzoQqhFj8a7wp9QT3tFRAL3NDGk=";
    };

    sourceRoot = "mvmctl-aarch64-apple-darwin";

    nativeBuildInputs = [
      pkgs.darwin.sigtool
      pkgs.darwin.cctools
    ];

    dontConfigure = true;
    dontBuild = true;
    # Prebuilt, signed below; don't let fixup rewrite the Mach-O files.
    dontStrip = true;
    dontPatchShebangs = true;

    installPhase = ''
      runHook preInstall

      # Keep the release layout intact: mvmctl finds its host helpers and
      # libmvm_hostlib.dylib next to the real binary. Expose every executable
      # on PATH via symlinks, like install.sh does in ~/.local/bin.
      mkdir -p $out/libexec/mvmctl $out/bin $out/share/man/man1
      cp -R . $out/libexec/mvmctl/
      for f in $out/libexec/mvmctl/mvm*; do
        [ -f "$f" ] && [ -x "$f" ] && ln -s "$f" $out/bin/
      done
      cp man/*.1 $out/share/man/man1/

      runHook postInstall
    '';

    # Use the entitlement profiles the release ships (same as install.sh):
    # mvmctl gets com.apple.security.virtualization, mvm-hvf-supervisor gets
    # com.apple.security.hypervisor. Neither can boot a VM without them.
    postFixup = ''
      export CODESIGN_ALLOCATE=${pkgs.darwin.cctools}/bin/codesign_allocate
      dir=$out/libexec/mvmctl
      codesign --sign - --force --entitlements $dir/assets/mvmctl.entitlements $dir/mvmctl
      codesign --sign - --force --entitlements $dir/assets/mvm-supervisor.entitlements $dir/mvm-hvf-supervisor
    '';

    meta = {
      description = "Manage secure microVMs (pinned prebuilt darwin release)";
      homepage = "https://github.com/tinylabscom/mvm";
      platforms = [ "aarch64-darwin" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      mainProgram = "mvmctl";
    };
  };
in
{
  environment.systemPackages = lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [ mvmctl ];
}
