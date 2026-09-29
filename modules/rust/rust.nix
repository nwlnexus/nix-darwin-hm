{
  config,
  pkgs,
  lib,
  ...
}:
# Global Rust tooling and hygiene for dev machines.
#
# This module does NOT install a Rust toolchain -- `rustup` (from base.nix)
# owns that, and it makes juggling toolchains far easier than a pinned Nix
# derivation would. What we template here are the *global settings* every dev
# machine should share, plus the tools and the scheduled job that keep `target/`
# bloat from silently eating hundreds of GB (the concrete incident: two Rust
# repos held ~51 GB of stale `target/` between them).
#
# Enabled fleet-wide via `d.profiles.dev.rust.enable` (see modules/profiles.nix,
# which defaults it to follow the dev profile) and imported from
# modules/profiles/dev.nix.
let
  # One shared target dir for every project, so dependency builds are not
  # duplicated per-repo and there is a single place to sweep. `cargo-sweep`
  # discovers `.fingerprint` dirs by walking, so it sweeps this cleanly.
  #
  # Lives under ~/projects (the external disk) on purpose: the internal boot
  # volume filled up when this sat in ~/.cache (91 GB of target dirs).
  #
  # Set ONLY via ~/.cargo/config.toml ([build] target-dir, below), never via the
  # CARGO_TARGET_DIR env var: the env var overrides config.toml, so a stale copy
  # (session variable, launchctl setenv) silently sends builds back to the
  # wrong disk. Per-worktree overrides (e.g. itpulse) can still export it.
  cargoCacheDir = "${config.home.homeDirectory}/projects/.cache/cargo";
  cargoTargetDir = "${cargoCacheDir}/target";

  sweepLogDir = "${config.home.homeDirectory}/.cache/cargo-sweep";

  # Time-based sweep. cargo-sweep only discovers *Rust projects* (dirs with a
  # Cargo.toml) and resolves each one's target dir through `cargo metadata`,
  # which honours CARGO_TARGET_DIR. A shared target dir has no Cargo.toml beside
  # it, so it is never found by pointing cargo-sweep at the cache dir; instead
  # run one pass per target dir with CARGO_TARGET_DIR set, over every project.
  # That also covers per-worktree `target-*` siblings (e.g. target-itpulse-*).
  # `cargo` comes from the launchd PATH (/run/current-system/sw/bin, rustup).
  # Stray in-tree `target/` dirs are left to `reclaim-disk`.
  cargo-sweep-scheduled = pkgs.writeShellApplication {
    name = "cargo-sweep-scheduled";
    runtimeInputs = [ pkgs.cargo-sweep ];
    text = ''
      projects="$HOME/projects"
      [ -d "$projects" ] || exit 0

      for tdir in ${lib.escapeShellArg cargoCacheDir}/target* "$HOME"/.cache/cargo/target*; do
        [ -d "$tdir" ] || continue
        echo "sweeping $tdir (artifacts unused > 30 days)"
        CARGO_TARGET_DIR="$tdir" cargo-sweep sweep --recursive --time 30 "$projects" || true
      done
    '';
  };
in
lib.mkMerge [
  {
    # sccache + cargo-sweep are helper tools, not the toolchain. sccache is
    # installed and size-capped, but intentionally NOT wired as a global
    # RUSTC_WRAPPER: that disables incremental compilation, which hurts the
    # fast edit/rebuild loop. Opt a project in when you want shared caching --
    # e.g. add to its .cargo/config.toml:  [build] rustc-wrapper = "sccache"
    # (or export RUSTC_WRAPPER=sccache in that repo's direnv).
    home.packages = [
      pkgs.sccache
      pkgs.cargo-sweep
    ];

    home.sessionVariables = {
      # Cap the sccache cache so it cannot grow without bound.
      SCCACHE_CACHE_SIZE = "10G";
    };

    # Consolidate all cargo build output into one shared, sweepable location.
    # Deliberately not CARGO_TARGET_DIR -- see the note on cargoCacheDir.
    home.file.".cargo/config.toml".text = ''
      [build]
      target-dir = "${cargoTargetDir}"
    '';
  }

  # launchd + the reclaim helper are macOS-only. The dev fleet is Darwin; a
  # NixOS host would want a systemd timer instead (not needed today).
  (lib.mkIf pkgs.stdenv.isDarwin {
    # On-demand "give me space back" button, ready on every dev machine.
    # Non-destructive (regenerable caches only); see the script for details.
    home.file.".local/bin/reclaim-disk" = {
      source = ./reclaim-disk.sh;
      executable = true;
    };

    # Ensure the log dir exists before launchd tries to write into it.
    home.activation.cargoSweepLogDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${lib.escapeShellArg sweepLogDir}
    '';

    # Weekly sweep: Sundays at 11:00. Removes build artifacts untouched for
    # 30+ days without forcing rebuilds of anything you are actively working on.
    launchd.agents.cargo-sweep = {
      enable = true;
      config = {
        ProgramArguments = [ "${cargo-sweep-scheduled}/bin/cargo-sweep-scheduled" ];
        StartCalendarInterval = [
          {
            Weekday = 0;
            Hour = 11;
            Minute = 0;
          }
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          PATH = lib.concatStringsSep ":" [
            "/etc/profiles/per-user/${config.home.username}/bin"
            "/run/current-system/sw/bin"
            "/nix/var/nix/profiles/default/bin"
            "/usr/bin"
            "/bin"
            "/usr/sbin"
            "/sbin"
          ];
        };
        RunAtLoad = false;
        StandardOutPath = "${sweepLogDir}/launchd.out.log";
        StandardErrorPath = "${sweepLogDir}/launchd.err.log";
      };
    };
  })
]
