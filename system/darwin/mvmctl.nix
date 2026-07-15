# Recent mvmctl (microVM CLI) provisioned from the pinned prebuilt GitHub
# release. There is no Homebrew formula, and crates.io only carries the older
# Lima-based 0.13.0 (wrong architecture for Apple Silicon), so we fetch the
# release binary and re-sign it. The libkrun/libkrunfw/gvproxy runtime deps
# come from Homebrew (libkrun/krun tap) — see ./brew.nix.
#
# Bump: change `version` + `hash` (get hash via `nix hash file <tarball>`).
{ pkgs, lib, ... }:

let
  version = "0.16.1";

  mvmctl = pkgs.stdenvNoCC.mkDerivation {
    pname = "mvmctl";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/tinylabscom/mvm/releases/download/v${version}/mvmctl-aarch64-apple-darwin.tar.gz";
      hash = "sha256-iakVHdc6tH6IE8xJoXJBovukUMt+nebDnoFt9KAtlMM=";
    };

    sourceRoot = "mvmctl-aarch64-apple-darwin";

    nativeBuildInputs = [
      pkgs.darwin.sigtool
      pkgs.darwin.cctools
    ];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      # Keep the release layout intact — mvmctl resolves resources/ relative to
      # the real binary path — then expose it on PATH via a symlink.
      mkdir -p $out/libexec/mvmctl $out/bin $out/share/man/man1
      cp -R . $out/libexec/mvmctl/
      ln -s $out/libexec/mvmctl/mvmctl $out/bin/mvmctl
      cp man/*.1 $out/share/man/man1/ || true

      runHook postInstall
    '';

    # Re-sign with the virtualization entitlement so mvmctl can drive Apple
    # Virtualization / libkrun. disable-library-validation lets the adhoc-signed
    # binary load Homebrew's differently-signed libkrunfw at runtime.
    postFixup = ''
      export CODESIGN_ALLOCATE=${pkgs.darwin.cctools}/bin/codesign_allocate
      codesign --sign - --force \
        --entitlements ${./mvmctl.entitlements} \
        $out/libexec/mvmctl/mvmctl
    '';

    meta = {
      description = "Manage secure microVMs (pinned prebuilt darwin release)";
      homepage = "https://gomicrovm.com";
      platforms = lib.platforms.darwin;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
{
  environment.systemPackages = [ mvmctl ];
}
