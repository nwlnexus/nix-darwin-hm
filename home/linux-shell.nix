# Shell wiring for standalone home-manager on Linux. On nix-darwin/NixOS
# these live in the system shell modules (system/darwin/shells.nix,
# system/nixos/shells.nix, system/shells.nix).
{
  config,
  lib,
  ...
}:
let
  home = config.home.homeDirectory;
  repo = "${home}/projects/personal/nix-darwin-hm";
in
{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
    # Trust exactly the two HM-managed tree hooks (home/default.nix), so they
    # load without `direnv allow` and keep working when their content changes.
    config.whitelist.exact = [
      "${home}/projects/personal/.envrc"
      "${home}/projects/work/.envrc"
    ];
  };

  # home/default.nix disables this because nix-darwin activates mise itself.
  programs.mise.enableZshIntegration = lib.mkForce true;

  # mise shims are symlinks to the mise binary; the bootstrap removes the
  # native one, so point them at this generation's mise.
  home.activation.miseReshim = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${config.programs.mise.package}/bin/mise reshim || true
  '';

  # rustup's toolchain (native install); ~/.zshenv no longer sources ~/.cargo/env.
  home.sessionPath = [ "${home}/.cargo/bin" ];

  home.shellAliases.switch = "${repo}/scripts/linux-switch.sh";
}
