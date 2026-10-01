# Home-manager side of the `d.shell` convenience options: modules set
# d.shell.{aliases,variables,sources}; this applies them. Imported by the
# system module (modules/shell.nix) on nix-darwin/NixOS and directly by
# home/standalone.nix on standalone home-manager hosts.
{ config, lib, ... }:

with lib;

let
  cfg = config.d.shell;
in

{
  options.d.shell = {
    aliases = mkOption {
      type = types.attrs;
      default = { };
    };

    variables = mkOption {
      type = types.attrs;
      default = { };
    };

    sources = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };
  };

  config = {
    home.sessionVariables = cfg.variables;
    home.shellAliases = cfg.aliases // {
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";

      clear = "tput reset";
      grep = "rg";
      mkdir = "mkdir -p";
    };
  };
}
