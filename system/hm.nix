{
  config,
  inputs,
  lib,
  version,
  user,
  theme,
  ...
}:

with lib;

let
  cfg = config.d.hm;
in

{
  options.d.hm = mkOption {
    type = types.listOf types.deferredModule;
    default = [ ];
  };

  config = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      sharedModules = [
        inputs.mac-app-util.homeManagerModules.default
      ];

      extraSpecialArgs = {
        inherit
          version
          user
          theme
          inputs
          ;
      };

      users.${user} = {
        imports = cfg ++ [
          inputs.nix-index.homeModules.nix-index
          inputs.op-secrets.hmModules.default
          ../home
        ];
      };
    };
  };
}
