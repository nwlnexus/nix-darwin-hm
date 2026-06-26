{
  description = "NWL NixOS ❄ / MacOS 🍏 Configuration";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";

    # nix-darwin
    darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs-stable";

    # Home manager
    hm.url = "github:nix-community/home-manager/release-26.05";
    hm.inputs.nixpkgs.follows = "nixpkgs-stable";

    hardware.url = "github:NixOS/nixos-hardware";

    persistence.url = "github:nix-community/impermanence";

    flake-parts.url = "github:hercules-ci/flake-parts";
    utils.url = "github:gytis-ivaskevicius/flake-utils-plus";
    nixos-flake.url = "github:srid/nixos-flake";

    nix-index.url = "github:nix-community/nix-index-database";
    nix-index.inputs.nixpkgs.follows = "nixpkgs-stable";

    vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    vscode-extensions.inputs.nixpkgs.follows = "nixpkgs-stable";

    rust-overlay.url = "github:oxalica/rust-overlay";

    # Devshell
    treefmt-nix.url = "github:numtide/treefmt-nix";

    mac-app-util.url = "github:hraban/mac-app-util";

    op-secrets.url = "github:nwlnexus/nix-op-secrets";
    op-secrets.inputs.nixpkgs.follows = "nixpkgs-stable";
  };

  outputs =
    inputs@{ self, hardware, ... }:
    let
      inherit (inputs.utils.lib) mkFlake;
      inherit (inputs.nixpkgs.lib.filesystem) listFilesRecursive;
      inherit (inputs.nixpkgs.lib) listToAttrs hasSuffix removeSuffix;
      PROJECT_ROOT = builtins.toString ./.;

      nixosConfig = {
        system = "x86_64-linux";

        specialArgs = {
          inherit hardware;
        };

        modules = [
          inputs.persistence.nixosModule
          inputs.hm.nixosModules.home-manager
          ./system/nixos
        ];
      };

      armNixosConfig = {
        system = "aarch64-linux";
        channelName = "nixpkgs";

        specialArgs = {
          inherit hardware;
        };

        modules = [
          inputs.persistence.nixosModule
          inputs.hm.nixosModules.home-manager
          ./system/nixos
        ];
      };

      darwinMConfig = {
        system = "aarch64-darwin";
        output = "darwinConfigurations";
        builder = inputs.darwin.lib.darwinSystem;

        modules = [
          inputs.hm.darwinModules.home-manager
          inputs.mac-app-util.darwinModules.default
          ./system/darwin
        ];
      };

      darwinConfig = {
        system = "x86_64-darwin";
        output = "darwinConfigurations";
        builder = inputs.darwin.lib.darwinSystem;

        modules = [
          inputs.hm.darwinModules.home-manager
          inputs.mac-app-util.darwinModules.default
          ./system/darwin
        ];
      };

      mkHosts =
        dir:
        let
          platform =
            if hasSuffix "darwinM" dir then
              darwinMConfig
            else if hasSuffix "darwin" dir then
              darwinConfig
            else if hasSuffix "arm" dir then
              armNixosConfig
            else
              nixosConfig;
          nixFiles = builtins.filter (file: hasSuffix ".nix" file) (listFilesRecursive dir);
        in
        listToAttrs (
          map (host: {
            name = removeSuffix ".nix" (baseNameOf host);
            value = platform // {
              modules = platform.modules ++ [ host ];
            };
          }) nixFiles
        );

    in
    mkFlake {
      inherit self inputs;

      channelsConfig = {
        allowUnfree = true;
      };

      channels = {
        nixpkgs = { };
        nixpkgs-stable = { };
      };

      sharedOverlays = [
        inputs.vscode-extensions.overlays.default
        inputs.rust-overlay.overlays.default
      ];

      hostDefaults = {
        channelName = "nixpkgs-stable";
        modules = [ ./system ];

        extraArgs = {
          user = "nwilliams-lucas";
          theme = "catppuccin";
          version = "26.05";
          PROJECT_ROOT = PROJECT_ROOT;
        };
      };

      hosts =
        (mkHosts ./hosts/nixos)
        // (mkHosts ./hosts/nixos-arm)
        // (mkHosts ./hosts/darwinM)
        // (mkHosts ./hosts/darwin);

      outputsBuilder = channels: {
        formatter = inputs.treefmt-nix.lib.mkWrapper channels.nixpkgs-stable {
          projectRootFile = "flake.nix";
          programs.nixfmt = {
            enable = true;
            package = channels.nixpkgs-stable.nixfmt;
          };
        };
      };
    };
}
