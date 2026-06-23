{
  pkgs,
  lib,
  config,
  ...
}:

{
  config = lib.mkIf config.d.profiles.dev.enable {
    # claudeMem is a home-manager option (declared in home/apps/claude-mem.nix),
    # so it must be set inside the home-manager scope via d.hm, not at the
    # nix-darwin system level.
    d.hm = [
      { d.apps.claudeMem.enable = true; }
    ];

    environment.systemPackages = with pkgs; [
      github-cli
      lazygit
      asdf-vm
      vscode
      azure-cli
      dotnet-sdk_8
      powershell
      kdoctor
      nixd
      postgresql
    ];

    homebrew = {
      brews = [
        "Azure/kubelogin/kubelogin"
        "opentofu"
        "derailed/k9s/k9s"
        "python3"
        "pipx"
        "doctl"
        "kubectl"
        "helm"
        "gemini-cli"
        "yq"
        "argocd"
        "neonctl"
        "fluxcd/tap/flux"
        "kubecm"
        "flyctl"
      ];
      casks = [
        "temurin@20"
      ];
      taps = [
        "derailed/k9s"
        "Azure/kubelogin"
      ];
    };
  };
}
