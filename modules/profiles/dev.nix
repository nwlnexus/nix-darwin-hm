{
  pkgs,
  lib,
  config,
  ...
}:

{
  config = lib.mkIf config.d.profiles.dev.enable {
    d.hm = [
      # memory-watchdog and the repomix-pack sweep are retired. Home Manager
      # unloads the memory-watchdog launchd agent on its own; this removes the
      # state/log caches they left behind, until every host has switched —
      # then delete this block. Idempotent and fail-soft.
      (
        { config, lib, ... }:
        {
          home.activation.retiredAgentsCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            rm -rf "${config.home.homeDirectory}/.cache/memory-watchdog" \
                   "${config.home.homeDirectory}/.cache/repomix-pipeline" || true
          '';
        }
      )
    ]
    ++ lib.optionals config.d.profiles.dev.rust.enable [ ../rust/rust.nix ];

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
