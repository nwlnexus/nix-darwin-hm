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

    op-secrets.url = "github:nwlnexus/nix-op-secrets";
    op-secrets.inputs.nixpkgs.follows = "nixpkgs-stable";

    # atuin source (built in home/cli/atuin.nix): one atuin version on every
    # host for sync, newer than nixpkgs ships. Source only: the flake fetches
    # its Rust toolchain at eval time (IFD), which breaks cross-platform eval.
    atuin.url = "github:atuinsh/atuin/v18.23.0";
    atuin.flake = false;

    # Reusable coding-agent skills (SKILL.md dirs under skills/). Source only;
    # home/cli/claude and home/agent-host symlink them into the Claude config
    # dirs. Bump with `nix flake update agent-skills`.
    agent-skills.url = "github:nwlnexus/agent-skills";
    agent-skills.flake = false;

    # Claude Code memory hooks (packages/memory-hooks) for home/cli/memory.
    # olympus-sdk is PRIVATE, so this is read over ssh (the user's key; the
    # 1Password agent on Macs), not through the github: fetcher. Source only
    # (flake = false); only the packages/memory-hooks subtree is installed,
    # the rest of the checkout never enters a host's closure. Pinned by
    # flake.lock: bump with `nix flake update olympus-sdk` after hooks change.
    olympus-sdk.url = "git+ssh://git@github.com/nwlnexus/olympus-sdk?ref=main";
    olympus-sdk.flake = false;

    # OS layer for non-NixOS Linux hosts (hosts/linux/*.nix → systemConfigs).
    # Pinned to upstream main after v1.1.0 and NOT following our nixpkgs: its
    # NixOS-module imports must match its own pinned nixpkgs (the combination
    # upstream CI builds and tests). v1.1.0 + our nixpkgs failed its test suite
    # (fixed upstream in f0f397bd0, "add writable $HOME directory in tests");
    # main + our nixpkgs fails on removed NixOS modules. Move to a tag later.
    system-manager.url = "github:numtide/system-manager/2473258afe1f7fbaa6229dc77961dd8a89ca713e";
  };

  outputs =
    inputs@{ self, hardware, ... }:
    let
      inherit (inputs.utils.lib) mkFlake;
      inherit (inputs.nixpkgs.lib.filesystem) listFilesRecursive;
      inherit (inputs.nixpkgs) lib;
      inherit (inputs.nixpkgs.lib) listToAttrs hasSuffix removeSuffix;
      PROJECT_ROOT = builtins.toString ./.;

      inherit (inputs.nixpkgs.lib)
        filterAttrs
        mapAttrs
        mapAttrs'
        nameValuePair
        recursiveUpdate
        ;

      # The inputs the mkFlake hosts (darwin, NixOS) see. flake-utils-plus probes every input's attributes
      # (`? legacyPackages`, `? outputs`), and on a flake = false input that forces the fetch, so every host
      # evaluation needed the PRIVATE olympus-sdk input. Here it is a lazy wrapper with the same attributes, the
      # same outPath (so "${inputs.olympus-sdk}" is the same store path) and nothing fetched until a host reads
      # it: a host that never does (a work-only Mac, olympus-sdk #691) evaluates without access to that repo.
      lazySource =
        src:
        lib.genAttrs [
          "lastModified"
          "lastModifiedDate"
          "narHash"
          "outPath"
          "rev"
          "revCount"
          "shortRev"
          "sourceInfo"
          "submodules"
        ] (name: src.${name});
      hostInputs = inputs // {
        olympus-sdk = lazySource inputs.olympus-sdk;
      };

      sharedArgs = {
        user = "nwilliams-lucas";
        theme = "catppuccin";
        version = "26.05";
        inherit PROJECT_ROOT;
      };

      sharedOverlays = [
        inputs.vscode-extensions.overlays.default
        inputs.rust-overlay.overlays.default
      ];

      # Linux hosts managed by standalone home-manager (+ system-manager).
      # hosts/linux/<hostname>.nix returns { platform; home; os?; }.
      linuxHosts = listToAttrs (
        map (f: {
          name = removeSuffix ".nix" (baseNameOf f);
          value = import f;
        }) (builtins.filter (hasSuffix ".nix") (listFilesRecursive ./hosts/linux))
      );

      pkgsFor =
        platform:
        import inputs.nixpkgs-stable {
          system = platform;
          config.allowUnfree = true;
          overlays = sharedOverlays;
        };

      homeConfigurations = mapAttrs' (
        hostname: host:
        nameValuePair "${sharedArgs.user}@${hostname}" (
          inputs.hm.lib.homeManagerConfiguration {
            pkgs = pkgsFor host.platform;
            extraSpecialArgs = sharedArgs // {
              inherit inputs hostname;
            };
            modules = [
              ./home/standalone.nix
              host.home
            ];
          }
        )
      ) linuxHosts;

      systemConfigs = mapAttrs (
        hostname: host:
        inputs.system-manager.lib.makeSystemConfig {
          specialArgs = sharedArgs // {
            inherit inputs hostname;
          };
          modules = [
            ./system/linux
            host.os
          ];
        }
      ) (filterAttrs (_: host: host ? os) linuxHosts);

      # CLIs pinned by flake.lock, used by scripts/linux-switch.sh.
      linuxPackages = listToAttrs (
        map (host: {
          name = host.platform;
          value = {
            system-manager = inputs.system-manager.packages.${host.platform}.default;
            home-manager = inputs.hm.packages.${host.platform}.default;
          };
        }) (builtins.attrValues linuxHosts)
      );

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
          ./system/darwin
        ];
      };

      darwinConfig = {
        system = "x86_64-darwin";
        output = "darwinConfigurations";
        builder = inputs.darwin.lib.darwinSystem;

        modules = [
          inputs.hm.darwinModules.home-manager
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
    let
      base = mkFlake {
        inherit self;
        inputs = hostInputs;

        channelsConfig = {
          allowUnfree = true;
        };

        channels = {
          nixpkgs = { };
          nixpkgs-stable = { };
        };

        inherit sharedOverlays;

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
    in
    base
    // {
      inherit homeConfigurations systemConfigs;
      packages = recursiveUpdate (base.packages or { }) linuxPackages;
    };
}
