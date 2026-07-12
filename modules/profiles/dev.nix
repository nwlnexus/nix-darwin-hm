{
  pkgs,
  lib,
  config,
  ...
}:

{
  config = lib.mkIf config.d.profiles.dev.enable {
    d.hm = [
      ../repomix/repomix.nix
    ];

    environment.systemPackages = with pkgs; [
      github-cli
      lazygit
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
        # mise now provided by home-manager (programs.mise) — see home/default.nix
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

      # Trust non-official taps for Homebrew 6.0 (see base.nix for rationale).
      # `fluxcd/tap` is auto-tapped by the qualified `fluxcd/tap/flux` brew, but
      # still needs to be trusted to avoid the "not trusted" warning/skip.
      extraConfig = ''
        tap "derailed/k9s", trusted: true
        tap "Azure/kubelogin", trusted: true
        tap "fluxcd/tap", trusted: true
      '';
    };
  };
}
