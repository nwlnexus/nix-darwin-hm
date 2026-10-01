{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # One atuin version on every host, because sync is on and a history DB
  # migrated by a newer atuin is refused by an older one ("migration ... was
  # previously applied but is missing"). nixpkgs lags (26.05: 18.15, unstable:
  # 18.21), so build atuin's own package definition from the pinned source
  # (flake input `atuin`) with the Rust its rust-toolchain.toml asks for,
  # from rust-overlay (no import-from-derivation). Bump both together.
  rust = pkgs.rust-bin.stable."1.98.0".minimal;

  # Cargo.toml uses TOML 1.1 syntax that builtins.fromTOML can't parse, so read
  # the `version = "..."` line that follows `[workspace.package]`.
  version =
    let
      lines = lib.splitString "\n" (builtins.readFile "${inputs.atuin}/Cargo.toml");
      header = lib.lists.findFirstIndex (
        l: l == "[workspace.package]"
      ) (throw "atuin: no [workspace.package]") lines;
      afterHeader = lib.drop (header + 1) lines;
      line = lib.findFirst (lib.hasPrefix "version = ") (throw "atuin: no workspace version") afterHeader;
    in
    lib.removeSuffix "\"" (lib.removePrefix "version = \"" line);
  atuin =
    (pkgs.callPackage "${inputs.atuin}/atuin.nix" {
      rustPlatform = pkgs.makeRustPlatform {
        cargo = rust;
        rustc = rust;
      };
    }).overrideAttrs
      (_: {
        inherit version;
      });
in
{
  programs.atuin = {
    enable = true;
    package = atuin;
  };
}
