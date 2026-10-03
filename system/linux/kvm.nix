# /dev/kvm access for mvmctl's Firecracker backend (modules/mvmctl/home.nix).
# Ubuntu owns users and groups here (userborn is off), so instead of adding the
# user to the `kvm` group, a udev rule grants them an rw ACL on /dev/kvm. That
# takes effect without a re-login, so the Remote Control services see it too.
# udev re-applies it on every kvm device event. The rule must sort after
# 73-seat-late.rules: its `uaccess` builtin rewrites the device's ACLs and
# would drop ours if it ran later.
{
  pkgs,
  user,
  ...
}:
let
  grant = "${pkgs.acl}/bin/setfacl -m u:${user}:rw /dev/kvm";
  rule = ''
    SUBSYSTEM=="misc", KERNEL=="kvm", RUN+="${grant}"
  '';
in
{
  environment.etc."udev/rules.d/99-mvm-kvm-acl.rules".text = rule;

  # Load the rule and grant now, on switch and at boot, without waiting for the
  # next device event. Restarts (re-runs) whenever the rule changes.
  systemd.services.mvm-kvm-acl = {
    description = "Grant ${user} access to /dev/kvm (mvmctl)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-trigger.service" ];
    restartTriggers = [ rule ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      /usr/bin/udevadm control --reload || true
      if [ -e /dev/kvm ]; then
        ${grant}
      else
        echo "no /dev/kvm (virtualization disabled?); skipping"
      fi
    '';
  };
}
