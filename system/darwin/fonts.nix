{ pkgs, lib, ... }:

{
  # Fonts
  fonts = {
    packages =
      with pkgs;
      [
        vista-fonts
        corefonts
      ]
      ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);
  };
}
