{ config, lib, ... }:

let
  cfg = config.d.profiles;

  mkBool =
    default:
    lib.mkOption {
      type = lib.types.bool;
      default = default;
    };
in

{
  # Profiles group related modules under a single flag for convenience.
  #
  # Notes:
  # - Not every module is profiled. By design.
  # - Individual modules can still be toggled independently.
  options.d.profiles = {
    # For: core configurations and programs e.g. system pkgs, fonts,
    # browsers, editors, terminal ..etc.
    base = {
      enable = mkBool true;

      # How a Mac gets Tailscale: "app" = the tailscale-app cask (GUI, per-user), "formula" = the Homebrew
      # `tailscale` formula only, run as a root LaunchDaemon (`sudo brew services start tailscale`) for
      # unattended hosts. Declaring the formula also keeps `brew bundle --cleanup` from removing it.
      tailscale = lib.mkOption {
        type = lib.types.enum [
          "app"
          "formula"
        ];
        default = "app";
      };

      # The `atlas` CLI from the nwlnexus/olympus Homebrew tap. Off on work-only hosts (d.workOnly) and on hosts
      # where atlas already runs as a daemon from its own install (data-hub: /usr/local/bin/atlas, self-updating),
      # where a second Homebrew copy would shadow it on PATH.
      atlas = lib.mkOption {
        type = lib.types.bool;
        default = !config.d.workOnly.enable;
        defaultText = lib.literalExpression "!config.d.workOnly.enable";
      };
    };

    # For: Minimal GUI applications
    gui-small.enable = mkBool false;

    # For: Full GUI applications
    gui-full.enable = mkBool false;

    # For: Developers. Developers. Developers :)
    dev = {
      enable = mkBool true;

      js.enable = mkBool cfg.dev.enable;
      # Rust tooling (shared target dir, sccache, scheduled sweep) is uniform
      # across the dev fleet, so it follows the dev profile like js does.
      rust.enable = mkBool cfg.dev.enable;

      # Per machine
      go.enable = mkBool false;
      py.enable = mkBool false;
    };

    # For: Corporate programs e.g. Zoom, Slack, etc.
    business.enable = mkBool false;

    # For: Gaming related programs e.g. Steam
    gaming.enable = mkBool false;
  };

  imports = [
    ./profiles/base.nix
    ./profiles/dev.nix
    ./profiles/gui-small.nix
    ./profiles/gui-full.nix
    ./profiles/business.nix
    # ./profiles/gaming.nix
  ];
}
