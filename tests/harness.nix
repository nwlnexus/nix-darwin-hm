# Sanity checks for the test harness itself.
{ flake, lib }:
let
  snap = import ./lib/darwin-snapshot.nix {
    inherit flake;
    host = "NWL-MMINI";
  };
in
{
  testSnapshotHasNoStoreHashes = {
    expr = builtins.match ".*/nix/store/[a-z0-9]{32}-.*" (builtins.toJSON snap) == null;
    expected = true;
  };
}
