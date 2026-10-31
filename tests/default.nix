# Evaluation tests. Run with `just test`; prints the failures, `[]` = pass.
# Each suite is `{ flake, lib }: { test<Name> = { expr; expected; }; }`.
{
  flake ? builtins.getFlake (toString ../.),
}:
let
  lib = flake.inputs.nixpkgs.lib;
  suites = [
    ./harness.nix
    ./standalone.nix
    ./portability.nix
    ./system-manager.nix
    ./scripts.nix
    ./agent-host.nix
    ./agent-host-darwin.nix
    ./work-only.nix
    ./linuxbrew.nix
    ./memory.nix
    ./claude-harness.nix
    ./server.nix
  ];
in
lib.debug.runTests (lib.foldl' (acc: f: acc // import f { inherit flake lib; }) { } suites)
