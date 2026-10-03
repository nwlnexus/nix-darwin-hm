# Home-manager module: installs mvmctl (./package.nix) on the hosts that
# import it (macOS via system/darwin/default.nix, Linux agent hosts via
# home/standalone.nix). Linux also needs /dev/kvm access: system/linux/kvm.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.packages = [ (pkgs.callPackage ./package.nix { }) ];

  # A manual `curl … | sh` install puts mvmctl + mvm-* helpers in ~/.local/bin
  # (newer installers symlink them into ~/.local/lib/mvm). ~/.local/bin is ahead
  # of the Nix profiles on PATH, so it would shadow this package.
  # Idempotent: gated on ~/.local/bin/mvmctl, so it's a no-op once removed.
  # `run` honours home-manager's dry-run mode.
  home.activation.mvmctlManualInstallCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mvmBin="${config.home.homeDirectory}/.local/bin"
    if [ -e "$mvmBin/mvmctl" ] || [ -L "$mvmBin/mvmctl" ]; then
      run rm -f "$mvmBin/mvmctl" "$mvmBin"/mvm-*
      run rm -rf "${config.home.homeDirectory}/.local/lib/mvm"
    fi
  '';
}
