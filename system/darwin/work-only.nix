# Work-only Macs (olympus-sdk #691): `d.workOnly.enable = true` in a nix-darwin host turns on the home-manager
# side (home/work-only.nix) for the primary user, and keeps the private `olympus-sdk` input out of the system:
# system/darwin/default.nix links every flake input into /etc/nix/inputs, which would put that input in the
# closure and fetch it. With this on (and the lazy input wrapper in flake.nix), the host neither needs access to
# it nor carries it (tests/work-only-private-input.sh). Off by default: the other Macs are unchanged
# (`just check-darwin`).
{
  config,
  lib,
  user,
  ...
}:
let
  cfg = config.d.workOnly;
  # Inputs a work-only host must not reference.
  personalInputs = [ "olympus-sdk" ];
in
{
  options.d.workOnly.enable = lib.mkEnableOption "work-only mode for this Mac and its primary user (home/work-only.nix)";

  config = lib.mkIf cfg.enable {
    home-manager.users.${user}.d.workOnly.enable = true;

    environment.etc = lib.listToAttrs (
      map (name: lib.nameValuePair "nix/inputs/${name}" { enable = false; }) personalInputs
    );
  };
}
