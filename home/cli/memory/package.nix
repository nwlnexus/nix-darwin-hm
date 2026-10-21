# The Claude Code memory-gateway hooks (olympus-sdk packages/memory-hooks), installed unchanged.
#
# `src` is the packages/memory-hooks subtree of the (private) olympus-sdk flake input. Only bin/ and
# share/memory/ are installed, byte for byte and with the executable bits kept; shebangs are NOT rewritten
# (dontFixup): the scripts are POSIX `#!/bin/sh`, locate themselves through $0 (so no wrapper may sit in
# front of them) and find their jq/awk libraries through MEMORY_SHARE_DIR or ../share/memory. Their runtime
# tools come from the hook command line (see default.nix), not from a wrapper.
{
  lib,
  stdenvNoCC,
  jq,
  src,
  rev ? null,
}:
stdenvNoCC.mkDerivation {
  pname = "memory-hooks";
  version = if rev == null then "unstable" else "0-unstable-${builtins.substring 0 8 rev}";
  inherit src;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -d $out/bin $out/share/memory $out/nix-support
    cp -p bin/* $out/bin/
    cp -p share/memory/* $out/share/memory/
    printf '%s\n' ${
      lib.escapeShellArg (if rev == null then "unknown" else rev)
    } > $out/nix-support/source-rev
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ jq ];
  installCheckPhase = ''
    runHook preInstallCheck
    # Everything the README says must be installed is there and the scripts parse.
    for f in bin/memory-capture bin/memory-session-start bin/memory-mcp-headers; do
      test -x $out/$f
      sh -n $out/$f
    done
    for f in lib.sh transport.sh normalize.jq redact.jq; do test -f $out/share/memory/$f; done
    sh -n $out/share/memory/lib.sh
    sh -n $out/share/memory/transport.sh
    # The jq filters compile and run (normalize.jq includes redact.jq through -L); the argument names are the ones
    # bin/memory-capture passes.
    jq -R -n -c -L $out/share/memory --argjson maxturn 8000 --argjson maxtool 1000 \
      -f $out/share/memory/normalize.jq < /dev/null > /dev/null
    # The headers helper prints exactly the documented object (design 11) from a throwaway key file.
    k=$(mktemp); printf 'mgw_test\n' > $k
    test "$(MEMORY_KEY_FILE=$k $out/bin/memory-mcp-headers)" = '{"Authorization":"Bearer mgw_test"}'
    rm -f $k
    runHook postInstallCheck
  '';

  passthru = {
    inherit rev;
  };

  meta = {
    description = "Claude Code capture and recall hooks for the on-prem memory gateway (olympus-sdk epic #444)";
    platforms = lib.platforms.unix;
  };
}
