# mvmctl (microVM CLI) from the pinned prebuilt GitHub release, laid out the
# way upstream's install.sh does it. No extra runtime deps:
#   macOS 26+ Apple Silicon -> in-house HVF backend (no libkrun/Homebrew libs)
#   Linux + /dev/kvm        -> Firecracker, which mvmctl fetches itself
# `mvmctl doctor` checks the host; `mvmctl bootstrap` prewarms its caches.
#
# Bump: change `version` + every `hash`. Take each tarball's sha256 from the
# release's checksums-sha256.txt and convert it with
# `nix hash convert --hash-algo sha256 --to sri <hex>`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  runtimeShell,
  darwin,
}:

let
  version = "0.22.0";

  targets = {
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      hash = "sha256-HyyAslOt0ow4VggOPzoQqhFj8a7wp9QT3tFRAL3NDGk=";
    };
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      hash = "sha256-UC6E6j+h/wSwE4+2w8tHs6cscw1yyPRo31XgHZnJTWQ=";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      hash = "sha256-2vsdnruUgLJoQcdyvuYyIBW3J7jMK8Z9ggVmMRARIvk=";
    };
  };

  target =
    targets.${stdenvNoCC.hostPlatform.system}
      or (throw "mvmctl: no prebuilt release for ${stdenvNoCC.hostPlatform.system}");

  # Linux workaround: mvmctl starts Firecracker under `systemd-run --scope` as
  # `sh -c 'echo $$ > "$0"; exec firecracker …'`. systemd-run >= 254 expands
  # `$$` to `$` itself (Ubuntu 26.04's 259 does), so the pid file reads "$",
  # mvmctl kills the VM as orphaned, and every boot fails. This shim, put on
  # mvmctl's PATH only, adds --expand-environment=no when the real systemd-run
  # supports it. Drop it once upstream passes that flag (or quotes `$$$$`).
  systemdRunShim = ''
    #!${runtimeShell}
    self="$(dirname "$0")"
    real=
    IFS=:
    for d in $PATH; do
      [ "$d" = "$self" ] && continue
      if [ -x "$d/systemd-run" ]; then real="$d/systemd-run"; break; fi
    done
    unset IFS
    [ -n "$real" ] || { echo "systemd-run: not found" >&2; exit 127; }
    case "$("$real" --help 2>/dev/null)" in
      *--expand-environment*) exec "$real" --expand-environment=no "$@" ;;
    esac
    exec "$real" "$@"
  '';
in
stdenvNoCC.mkDerivation {
  pname = "mvmctl";
  inherit version;

  src = fetchurl {
    url = "https://github.com/tinylabscom/mvm/releases/download/v${version}/mvmctl-${target.triple}.tar.gz";
    inherit (target) hash;
  };

  sourceRoot = "mvmctl-${target.triple}";

  # Linux executables are static; libmvm_hostlib.so (for the SDKs) only needs
  # libc from the process that loads it, so nothing needs patchelf.
  nativeBuildInputs =
    lib.optionals stdenvNoCC.hostPlatform.isLinux [ makeWrapper ]
    ++ lib.optionals stdenvNoCC.hostPlatform.isDarwin [
      darwin.sigtool
      darwin.cctools
    ];

  dontConfigure = true;
  dontBuild = true;
  # Prebuilt (and signed below on darwin); don't let fixup rewrite the binaries.
  dontStrip = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    # Keep the release layout intact: mvmctl finds its host helpers and
    # libmvm_hostlib next to the real binary. Expose every executable on PATH
    # via symlinks, like install.sh does in ~/.local/bin.
    mkdir -p $out/libexec/mvmctl $out/bin $out/share/man/man1
    cp -R . $out/libexec/mvmctl/
    for f in $out/libexec/mvmctl/mvm*; do
      [ -f "$f" ] && [ -x "$f" ] && ln -s "$f" $out/bin/
    done
    cp man/*.1 $out/share/man/man1/ 2>/dev/null || true
  ''
  + lib.optionalString stdenvNoCC.hostPlatform.isLinux ''

    mkdir -p $out/libexec/mvmctl-shims
    cat > $out/libexec/mvmctl-shims/systemd-run <<'SHIM'
    ${systemdRunShim}
    SHIM
    chmod +x $out/libexec/mvmctl-shims/systemd-run
    rm $out/bin/mvmctl
    makeWrapper $out/libexec/mvmctl/mvmctl $out/bin/mvmctl \
      --prefix PATH : $out/libexec/mvmctl-shims
  ''
  + ''

    runHook postInstall
  '';

  # Use the entitlement profiles the release ships (same as install.sh):
  # mvmctl gets com.apple.security.virtualization, mvm-hvf-supervisor gets
  # com.apple.security.hypervisor. Neither can boot a VM without them.
  postFixup = lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
    export CODESIGN_ALLOCATE=${darwin.cctools}/bin/codesign_allocate
    dir=$out/libexec/mvmctl
    codesign --sign - --force --entitlements $dir/assets/mvmctl.entitlements $dir/mvmctl
    codesign --sign - --force --entitlements $dir/assets/mvm-supervisor.entitlements $dir/mvm-hvf-supervisor
  '';

  meta = {
    description = "Manage secure microVMs (pinned prebuilt release)";
    homepage = "https://github.com/tinylabscom/mvm";
    platforms = builtins.attrNames targets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "mvmctl";
  };
}
