# The Linux arm64 VM of a server Mac (d.server.linuxVm; olympus-sdk #694, decision H20): a k3s agent VM run by Tart
# on Virtualization.framework, headless, on a bridged NIC so it has its own address on the cluster network.
#
# - Tart comes from Homebrew (tap cirruslabs/cli) through this repo's brew module.
# - A LaunchDaemon (scripts/server/vm-run.sh) runs `tart run --no-graphics --net-bridged=<iface> <name>` at boot with
#   nobody logged in, KeepAlive. It waits for the marker `server-vm-provision` writes.
# - `server-vm-provision` is the one-time, idempotent setup (scripts/server/vm-provision.sh). A switch never runs it.
#
# Daemon user: the primary user (UserName), not root and not a new account. Tart's own signature carries the
# com.apple.security.virtualization and com.apple.vm.networking entitlements, which is what Virtualization.framework
# checks for a bridged NIC, so no root is needed; the VM's disks live in the owner's ~/.tart as `tart` expects,
# and the same account runs `server-vm-provision`. A dedicated hidden user was rejected: it has no login session,
# no ~/.tart and no Homebrew ownership, all untested with Virtualization.framework. Cirrus Labs' own Orchard
# worker is run as a LaunchDaemon with a regular UserName in the same way. macOS (not Linux) guests are the ones
# that need a logged-in GUI session; a Linux guest with --no-graphics does not.
#
# Image: cirruslabs' Ubuntu 24.04 arm64 image, not the official cloud image. Tart cannot attach a cloud-init seed to
# a stock cloud image without converting it to a raw disk by hand; the cirruslabs image boots under Tart as is.
# Its default login (admin/admin) is dealt with by the provisioning script before the bridged NIC is ever used.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.server.linuxVm;
  server = config.d.server;
  user = config.system.primaryUser;
  home = "/Users/${user}";
  tart = "/opt/homebrew/bin/tart";
  marker = "${home}/.tart/${cfg.name}.provisioned";
  log = "/var/log/server-vm.log";

  run = pkgs.writeScript "server-vm-run" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ../../scripts/server/vm-run.sh}
  '';
  provisionScript = pkgs.writeScript "server-vm-provision.sh" ''
    #!${pkgs.bash}/bin/bash
    ${builtins.readFile ../../scripts/server/vm-provision.sh}
  '';
  provision = pkgs.writeShellScriptBin "server-vm-provision" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
        pkgs.gnugrep
      ]
    }:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
    export VM_NAME=${lib.escapeShellArg cfg.name}
    export VM_CPUS=${toString cfg.cpus}
    export VM_MEMORY_MB=${toString (cfg.memoryGiB * 1024)}
    export VM_DISK_GB=${toString cfg.diskGiB}
    export VM_IMAGE=${lib.escapeShellArg cfg.image}
    export VM_ANSIBLE_KEY_FILE=${lib.escapeShellArg cfg.ansibleKeyFile}
    export VM_OWNER=${lib.escapeShellArg user}
    export VM_MARKER=${lib.escapeShellArg marker}
    export TART_BIN=${tart}
    exec ${provisionScript} "$@"
  '';
in
{
  options.d.server.linuxVm = {
    enable = lib.mkEnableOption "the Tart-run Linux arm64 k3s agent VM (needs d.server.enable)";
    name = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}-vm";
      defaultText = lib.literalExpression ''"''${config.networking.hostName}-vm"'';
      description = "The Tart VM name.";
    };
    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "vCPUs.";
    };
    memoryGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Memory in GiB. On a 24 GB mini the VM takes 12 and macOS plus one runner job keep the rest.";
    };
    diskGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 150;
      description = "Disk size in GB (grown from the image's 20 GB at provisioning).";
    };
    bridgeInterface = lib.mkOption {
      type = lib.types.str;
      default = "en0";
      description = "The host interface the VM's NIC is bridged to (`tart run --net-bridged`).";
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/cirruslabs/ubuntu:24.04";
      description = "The OCI image `server-vm-provision` clones. Ubuntu 24.04 arm64.";
    };
    ansibleKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/server-vm/ansible.pub";
      description = "File with the one ssh public key the VM's `ansible` user accepts. The owner supplies it; it is a public key, but it is not in this repo.";
    };
  };

  config = lib.mkIf cfg.enable {
    homebrew.brews = [ "cirruslabs/cli/tart" ];
    homebrew.extraConfig = ''
      tap "cirruslabs/cli", trusted: true
    '';

    environment.systemPackages = [ provision ];

    launchd.daemons.server-vm = {
      serviceConfig = {
        Label = "io.olympus.server-vm";
        ProgramArguments = [ "${run}" ];
        UserName = user;
        EnvironmentVariables = {
          HOME = home;
          PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          VM_NAME = cfg.name;
          VM_BRIDGE = cfg.bridgeInterface;
          VM_MARKER = marker;
          TART_BIN = tart;
        };
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = log;
        StandardErrorPath = log;
      };
    };

    # launchd would create the log as root, which the daemon (running as the owner) could not write to.
    system.activationScripts.postActivation.text = ''
      if [ ! -e ${log} ]; then
        install -m 0640 -o ${lib.escapeShellArg user} -g wheel /dev/null ${log}
      fi
    '';

    assertions = [
      {
        assertion = server.enable;
        message = "d.server.linuxVm needs d.server.enable: the VM is part of the server role.";
      }
      {
        assertion = cfg.bridgeInterface != "";
        message = "d.server.linuxVm.bridgeInterface must name a host interface.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.ansibleKeyFile;
        message = "d.server.linuxVm.ansibleKeyFile must be an absolute path.";
      }
    ];
  };
}
