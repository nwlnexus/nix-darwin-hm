{
  config,
  lib,
  user,
  ...
}:

with lib;

let
  cfg = config.d.shell;
  profiles = config.d.profiles;

  # FIXME: remove later
  cfgHome = config.home-manager.users.${user}.d.shell;
in

{
  # System-level d.shell. Values set here are forwarded into home-manager,
  # where home/shell.nix applies them alongside the hm-level definitions.
  options.d.shell = {
    enable = mkOption {
      type = types.bool;
      default = profiles.base.enable;
    };

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
    # FIXME: remove later
    d.shell.sources = cfgHome.sources;

    d.hm = [
      ../home/shell.nix
      {
        d.shell.aliases = cfg.aliases;
        d.shell.variables = cfg.variables;
      }
    ];
  };
}
