# A store-hash-free, JSON-serialisable snapshot of an evaluated home-manager
# config. Used to prove refactors don't change a host's output: the source
# path leaks into derivations (PROJECT_ROOT, nix.linkInputs), so drvPath
# comparisons change on every commit, but this snapshot doesn't.
{ lib, hm }:
let
  norm =
    s:
    lib.concatMapStrings (x: if builtins.isList x then "/nix/store/HASH-" else x) (
      builtins.split "/nix/store/[a-z0-9]{32}-" s
    );
  show = v: if v == null then null else norm (toString v);
  enabled = lib.filterAttrs (_: f: f.enable);
in
{
  files = lib.mapAttrs' (
    _: f:
    lib.nameValuePair f.target {
      text = if f.text == null then null else norm f.text;
      source = if f.text != null then null else show f.source;
      inherit (f) executable;
    }
  ) (enabled hm.home.file);
  xdg = lib.mapAttrs (_: f: if f.text == null then show f.source else norm f.text) (
    enabled hm.xdg.configFile
  );
  sessionVariables = lib.mapAttrs (_: show) hm.home.sessionVariables;
  sessionPath = map show hm.home.sessionPath;
  shellAliases = hm.home.shellAliases;
  packages = lib.sort lib.lessThan (map lib.getName hm.home.packages);
  activation = lib.mapAttrs (_: e: norm e.data) hm.home.activation;
  launchdAgents = lib.attrNames (lib.filterAttrs (_: a: a.enable) (hm.launchd.agents or { }));
  systemdUserServices = lib.attrNames (hm.systemd.user.services or { });
}
