{
  pkgs,
  lib,
  user,
  version,
  ...
}:

let
  homePrefix = if pkgs.stdenv.isDarwin then "/Users" else "/home";
in

{
  imports = [
    ./ssh_config.nix
    ./autostart.nix
    ./eza.nix
    ./apps
  ];

  home = {
    file = {
      "nix-darwin-reinit" = {
        text = ''
          #!/usr/bin/env bash
          #
          # nix-darwin-reinit - Reinitialize nix-darwin after macOS system upgrades
          #
          # After macOS system updates, the system may overwrite Nix's shell configuration
          # files (/etc/zshrc and /etc/zprofile). This script backs up those files and
          # reapplies the nix-darwin configuration to restore Nix integration.
          #
          # Usage: nix-darwin-reinit
          #

          set -euo pipefail

          # Colors for output
          RED='\033[0;31m'
          GREEN='\033[0;32m'
          YELLOW='\033[1;33m'
          BLUE='\033[0;34m'
          NC='\033[0m' # No Color

          echo -e "''${BLUE}==> nix-darwin Reinitialization Script''${NC}"
          echo

          # Check if running on macOS
          if [[ "$(uname)" != "Darwin" ]]; then
            echo -e "''${RED}Error: This script is only for macOS systems.''${NC}"
            exit 1
          fi

          # Check if nix-darwin is available
          if ! command -v darwin-rebuild &> /dev/null; then
            echo -e "''${RED}Error: darwin-rebuild command not found. Is nix-darwin installed?''${NC}"
            exit 1
          fi

          # Default flake path
          FLAKE_PATH="''${HOME}/nix-darwin-hm"

          # Allow override via environment variable or argument
          if [[ $# -gt 0 ]]; then
            FLAKE_PATH="$1"
          fi

          # Verify flake path exists
          if [[ ! -d "$FLAKE_PATH" ]]; then
            echo -e "''${RED}Error: Flake path does not exist: $FLAKE_PATH''${NC}"
            echo -e "''${YELLOW}Usage: nix-darwin-reinit [flake-path]''${NC}"
            exit 1
          fi

          echo -e "''${BLUE}Using flake path:''${NC} $FLAKE_PATH"
          echo

          # Function to backup a file if it exists
          backup_file() {
            local file="$1"
            if [[ -f "$file" ]]; then
              local backup="''${file}.before-nix-darwin"
              echo -e "''${YELLOW}Backing up:''${NC} $file -> $backup"
              sudo mv "$file" "$backup"
            else
              echo -e "''${BLUE}Skipping:''${NC} $file (does not exist)"
            fi
          }

          # Backup shell configuration files
          echo -e "''${GREEN}Step 1: Backing up shell configuration files''${NC}"
          backup_file "/etc/zshrc"
          backup_file "/etc/zprofile"
          backup_file "/etc/bashrc"
          backup_file "/etc/bash.bashrc"
          echo

          # Rebuild nix-darwin configuration
          echo -e "''${GREEN}Step 2: Rebuilding nix-darwin configuration''${NC}"
          if darwin-rebuild switch --flake "$FLAKE_PATH"; then
            echo
            echo -e "''${GREEN}✓ nix-darwin reinitialization completed successfully!''${NC}"
            echo
            echo -e "''${BLUE}Note:''${NC} You may need to restart your terminal or run:"
            echo -e "  source /etc/static/zshrc"
          else
            echo
            echo -e "''${RED}✗ darwin-rebuild failed. Please check the error messages above.''${NC}"
            exit 1
          fi
        '';
        target = ".local/bin/nix-darwin-reinit";
        executable = true;
      };
      "Cloudflare_CA" = {
        text = ''
          -----BEGIN CERTIFICATE-----
          MIIDHTCCAsOgAwIBAgIURCw5MNDWeKV9xjY641rGsPE7MGcwCgYIKoZIzj0EAwIw
          gcAxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMRYwFAYDVQQHEw1T
          YW4gRnJhbmNpc2NvMRkwFwYDVQQKExBDbG91ZGZsYXJlLCBJbmMuMRswGQYDVQQL
          ExJ3d3cuY2xvdWRmbGFyZS5jb20xTDBKBgNVBAMTQ0dhdGV3YXkgQ0EgLSBDbG91
          ZGZsYXJlIE1hbmFnZWQgRzEgMzE2YzBiYTk0MjlmMzFjMTRlZGFmNzBhNDgyMjA3
          NjkwHhcNMjQxMjExMTkyOTAwWhcNMjkxMjExMTkyOTAwWjCBwDELMAkGA1UEBhMC
          VVMxEzARBgNVBAgTCkNhbGlmb3JuaWExFjAUBgNVBAcTDVNhbiBGcmFuY2lzY28x
          GTAXBgNVBAoTEENsb3VkZmxhcmUsIEluYy4xGzAZBgNVBAsTEnd3dy5jbG91ZGZs
          YXJlLmNvbTFMMEoGA1UEAxNDR2F0ZXdheSBDQSAtIENsb3VkZmxhcmUgTWFuYWdl
          ZCBHMSAzMTZjMGJhOTQyOWYzMWMxNGVkYWY3MGE0ODIyMDc2OTBZMBMGByqGSM49
          AgEGCCqGSM49AwEHA0IABPaQOVgkrzRB58TvmBomvaNH1cJoRZxtM1Z25eq/DnKZ
          8q2NWZL+N91rzKRKyJ62xJNz+EgFMAyWTIneN69rhPCjgZgwgZUwDgYDVR0PAQH/
          BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFH+i4Q5pdL5lRS/i3onS
          aKqOnrecMFMGA1UdHwRMMEowSKBGoESGQmh0dHA6Ly9jcmwuY2xvdWRmbGFyZS5j
          b20vM2U4ZTM0MTEtOTMxMC00ZTYxLTljNjUtYjUzOTEwZGNhODFhLmNybDAKBggq
          hkjOPQQDAgNIADBFAiBIiZVkJjfztxzPkimJIKtbQdY+wOrg1OJWNTS1spah7AIh
          AMLuNe00+2o61dUlmAACQHak55uSRHk99tRlP98Iv3gi
          -----END CERTIFICATE-----
        '';
        target = "${homePrefix}/${user}/Cloudflare_CA.pem";
      };
      "CurlRC" = {
        text = ''
          --cacert /etc/ssl/certs/ca-certificates.crt
        '';
        target = "${homePrefix}/${user}/.curlrc";
      };
      "direnv-hook-personal" = {
        text = ''
          #!/usr/bin/env bash
          # Tree-level direnv config for ~/projects/personal.
          # Sources ~/projects/personal/.env and exports its vars (incl. GITHUB_PERSONAL_ACCESS_TOKEN
          # for the `github` MCP server, scoped to the PERSONAL gh account).
          #
          # Note: direnv loads only the *nearest* .envrc. Repos with their own .envrc
          # will override this unless they also source ~/projects/personal/.env.

          set -a
          [ -f "${homePrefix}/${user}/projects/personal/.env" ] && . "${homePrefix}/${user}/projects/personal/.env"
          [ -f "${homePrefix}/${user}/projects/personal/.op-connect" ] && . "${homePrefix}/${user}/projects/personal/.op-connect"
          # The gh CLI reads GH_TOKEN (it ignores GITHUB_PERSONAL_ACCESS_TOKEN). Mirror the
          # tree-scoped PAT into GH_TOKEN so `gh` auto-selects the PERSONAL account here —
          # process-scoped via direnv, so no global `gh auth switch` and no cross-shell clash.
          [ -n "''${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && GH_TOKEN="''${GITHUB_PERSONAL_ACCESS_TOKEN}"
          set +a
        '';
        target = "${homePrefix}/${user}/projects/personal/.envrc";
      };
      "direnv-hook-work" = {
        text = ''
          #!/usr/bin/env bash
          # Tree-level direnv config for ~/projects/work.
          # Sources ~/projects/work/.env and exports its vars (incl. GITHUB_PERSONAL_ACCESS_TOKEN
          # for the `github` MCP server, scoped to the work gh account).
          #
          # Note: direnv loads only the *nearest* .envrc. Repos with their own .envrc
          # will override this unless they also source ~/projects/work/.env.

          set -a
          [ -f "${homePrefix}/${user}/projects/work/.env" ] && . "${homePrefix}/${user}/projects/work/.env"
          [ -f "${homePrefix}/${user}/projects/work/.op-connect" ] && . "${homePrefix}/${user}/projects/work/.op-connect"
          # The gh CLI reads GH_TOKEN (it ignores GITHUB_PERSONAL_ACCESS_TOKEN). Mirror the
          # tree-scoped PAT into GH_TOKEN so `gh` auto-selects the WORK account here —
          # process-scoped via direnv, so no global `gh auth switch` and no cross-shell clash.
          [ -n "''${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && GH_TOKEN="''${GITHUB_PERSONAL_ACCESS_TOKEN}"
          set +a
        '';
        target = "${homePrefix}/${user}/projects/work/.envrc";
      };
    };
    username = user;
    homeDirectory = lib.mkForce "${homePrefix}/${user}";
    stateVersion = version;

    sessionVariables = {
      HOMEBREW_BAT = "1";
      HOMEBREW_CURLRC = "1";
      GOPATH = "${homePrefix}/${user}/go";
    };

    sessionPath = [
      "${homePrefix}/${user}/.local/bin"
      "${homePrefix}/${user}/go/bin"
    ];
  };

  xdg.enable = true;
  programs.home-manager.enable = true;
  programs.go.enable = true;

  # mise — sole toolchain & version manager (asdf fully retired, no corepack).
  # Owns the global mise config declaratively (was a hand-edited
  # ~/.config/mise/config.toml); per-project versions still come from each
  # repo's mise.toml / .tool-versions / package.json "packageManager".
  # Activation is handled by system/darwin/shells.nix, so zsh integration is off
  # here to avoid double-activation.
  programs.mise = {
    enable = true;
    enableZshIntegration = false;
    globalConfig = {
      tools = {
        node = "24.18.0";
        pnpm = "11.9.0";
        # Migrated from the retired ~/.tool-versions (asdf global) so these
        # stay globally available but declaratively. Pinned to latest.
        bun = "1.3.14";
        terraform = "1.15.7";
        terraform-ls = "0.38.8";
        packer = "1.15.4";
        "npm:repomix" = "latest";
        # Zero runtime dependencies beyond Node itself (no native postinstall,
        # unlike gitnexus below) — see home/cli/claude/default.nix for the
        # install-hooks activation and nwlnexus/mnemosyne#33 for why this
        # replaced the nix flake package.
        "npm:@nwlnexus/mnemosyne" = "latest";
        # gitnexus needs native postinstall (tree-sitter grammars, onnxruntime, etc.).
        # mise passes --ignore-scripts=true for npm globals by default; with npm 11.16+
        # allow_builds becomes --allow-scripts=<pkgs> so only reviewed deps run scripts.
        "npm:gitnexus" = {
          version = "latest";
          allow_builds = [
            "gitnexus"
            "tree-sitter"
            "tree-sitter-c-sharp"
            "tree-sitter-cpp"
            "tree-sitter-go"
            "tree-sitter-java"
            "tree-sitter-javascript"
            "tree-sitter-php"
            "tree-sitter-python"
            "tree-sitter-ruby"
            "tree-sitter-rust"
            "tree-sitter-typescript"
            "onnxruntime-node"
            "@ladybugdb/core"
            "sharp"
            "protobufjs"
          ];
        };
      };
      settings = {
        # Read .nvmrc/.node-version (node) and package.json "packageManager"
        # (pnpm), so mise resolves the pnpm version from packageManager — no corepack.
        idiomatic_version_file_enable_tools = [
          "node"
          "pnpm"
        ];
        # Auto-install a pinned-but-missing tool on first use (already the mise
        # default; pinned here so a future default change can't silently disable
        # it) — entering a repo never requires a manual `mise install`.
        auto_install = true;
        # Implicitly trust mise.toml under the trees I own, skipping the
        # `mise trust` prompt there. Any other path (e.g. ~/projects/freelance,
        # or a one-off clone elsewhere) still requires an explicit `mise trust`.
        trusted_config_paths = [
          "${homePrefix}/${user}/projects/work"
          "${homePrefix}/${user}/projects/personal"
        ];
      };
    };
  };

  programs.zsh = {
    initContent = ''
      # Add ~/.zsh/completion to fpath for custom completions
      [[ -d ~/.zsh/completion ]] || mkdir -p ~/.zsh/completion
      if [[ ! " ''${fpath[*]} " =~ " $HOME/.zsh/completion " ]]; then
        fpath=(~/.zsh/completion $fpath)
      fi

      # --- OneDrive DTLR symlinks ---
      # Check for "~/OneDrive - DTLR, Inc" and link to ~/ODTLR
      if [[ -d "$HOME/OneDrive - DTLR, Inc" && ! -e "$HOME/ODTLR" ]]; then
        ln -s "$HOME/OneDrive - DTLR, Inc" "$HOME/ODTLR"
      fi

      # Check for "~/OneDrive - DTLR, Inc/Intune" and link to ~/Intune
      if [[ -d "$HOME/OneDrive - DTLR, Inc/Intune" && ! -e "$HOME/Intune" ]]; then
        ln -s "$HOME/OneDrive - DTLR, Inc/Intune" "$HOME/Intune"
      fi
    '';
  };

  xsession.numlock.enable = pkgs.stdenv.isLinux;
}
