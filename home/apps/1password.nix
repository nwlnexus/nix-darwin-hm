{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.d.apps.onepassword;
in

{
  options.d.apps.onepassword = {
    enable = mkOption {
      type = types.bool;
      default = true;
    };

    ssh = mkOption {
      type = types.submodule {
        options = {
          # https://developer.1password.com/docs/ssh/get-started
          key = mkOption {
            type = types.str;
            default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvhX5961G5kV7a9/p6nEBriBRUqE691VCcRDkot8EXD";
          };

          agent = mkOption {
            type = types.str;
            default =
              if pkgs.stdenv.isDarwin then
                "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
              else
                "~/.1password/agent.sock";
          };

          sign = mkOption {
            type = types.str;
            default =
              if pkgs.stdenv.isDarwin then
                "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
              else
                "${pkgs._1password-gui}/share/1password/op-ssh-sign";
          };
        };
      };
      default = { };
    };
  };

  config = mkIf cfg.enable {
    # Use for SSH Authentication and Signing
    d.shell.variables = {
      SSH_AUTH_SOCK = cfg.ssh.agent;
    };

    programs.ssh.extraConfig = ''
      IdentityAgent "${cfg.ssh.agent}"
    '';

    # Load 1Password Shell Plugins
    d.shell.sources = [
      "$HOME/.config/op/plugins.sh"
    ];

    d.autostart._1password-gui = {
      exec = "1password --silent";
    };

    # SSH keys are materialized to disk via the nix-op-secrets module
    # (imported in system/hm.nix). All secrets share the module-level
    # personal-account auth: `serviceAccountTokenFile` reads a raw token
    # written by you, out-of-band, before running nix:
    #
    #     mkdir -p ~/.config/personal && chmod 700 ~/.config/personal
    #     ( umask 077 \
    #         && grep -E '^OP_SERVICE_ACCOUNT_TOKEN=' ~/projects/personal/.env \
    #              | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" \
    #              > ~/.config/personal/1penv \
    #     )
    #     chmod 600 ~/.config/personal/1penv
    #
    # Filename uses `1penv` rather than `env` to avoid collision with the
    # many tools that auto-source `~/.config/*/env` files. If the file is
    # absent, op-secrets falls back to interactive auth.
    #
    # Autonomous-run expectation: every secret in this block is expected to
    # come from the module-level account (`my.1password.com`). The work key
    # below is the explicit exception — its per-secret `account` override
    # causes op-secrets to drop the module token for that fetch and fall
    # back to the interactive `op` session for `dtlrinc.1password.com`
    # (provided by the 1Password desktop app's CLI integration). If you need
    # work to be autonomous as well, give it its own
    # `serviceAccountTokenCommand` pointing at a work-account token file.
    op-secrets = {
      enable = true;
      secrets = {
        gitlab-work = {
          type = "sshKey";
          account = "my.1password.com";
          source = "op://Dev/44adgxe36ozbj2jyhwg3dfdyui";
          dest = "${config.home.homeDirectory}/.ssh/gitlab-work-gl";
          writePublicKey = true;
        };
        github-personal = {
          type = "sshKey";
          account = "my.1password.com";
          source = "op://Dev/ta7qkekssx6z5v2f27bksaotzi";
          dest = "${config.home.homeDirectory}/.ssh/id_ed25519";
          writePublicKey = true;
          # No per-secret overrides — inherits module-level account + token.
        };
        personal-env = {
          account = "my.1password.com";
          template = ../secrets/personal-env.tpl;
          dest = "${config.home.homeDirectory}/projects/personal/.env";
          mode = "0600";
        };
        work-env = {
          account = "dtlrinc.1password.com";
          template = ../secrets/work-env.tpl;
          dest = "${config.home.homeDirectory}/projects/work/.env";
          mode = "0600";
        };
        op-connect-env = {
          account = "my.1password.com";
          template = ../secrets/op-connect.tpl;
          dest = "${config.home.homeDirectory}/projects/personal/.op-connect";
          mode = "0600";
        };
      };
    };
  };
}
