# system-manager OS layer shared by every Linux agent host. Deliberately
# small: Ubuntu keeps owning sshd, Tailscale, apt and users; this manages
# Nix's config, GC, user lingering, and an sshd hardening drop-in.
{
  config,
  user,
  ...
}:
{
  # system-manager leaves its nix module off by default; we own nix.conf.
  nix.enable = true;

  # Ubuntu owns users and groups. system-manager enables userborn by default,
  # which would rewrite /etc/passwd and /etc/group from its NixOS defaults.
  services.userborn.enable = false;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Keep what the Nix installer's own nix.conf provides; we replace it.
    build-users-group = "nixbld";
    max-jobs = "auto";
    # "root" is already trusted by system-manager's own nix module.
    trusted-users = [ user ];
    download-buffer-size = 134217728; # 128 MiB, same as the Macs
    warn-dirty = false;
  };

  # Private-repo flake inputs read a token from here (optional include;
  # materialized by scripts/bootstrap-agent-host.sh). Same as system/nix.nix.
  nix.extraOptions = ''
    !include /etc/nix/github-token.conf
  '';

  # The Nix installer already wrote /etc/nix/nix.conf; back it up and replace.
  environment.etc."nix/nix.conf".replaceExisting = true;

  # Weekly GC + optimise, matching the Macs (system/nix.nix: Sundays, 30d).
  systemd.services.nix-gc = {
    description = "Nix garbage collection";
    startAt = "Sun *-*-* 03:00:00";
    serviceConfig.Type = "oneshot";
    script = ''
      ${config.nix.package}/bin/nix-collect-garbage --delete-older-than 30d
      ${config.nix.package}/bin/nix store optimise
    '';
  };

  # Lingering = this file existing; lets the user's systemd services (the
  # Remote Control servers) start at boot with nobody logged in.
  systemd.tmpfiles.rules = [
    "f /var/lib/systemd/linger/${user} 0644 root root -"
  ];

  # Mirrors the host's hand-written 10-hardening.conf so new hosts get it too.
  # 05- sorts before 50-cloud-init.conf; sshd keeps the first value it reads.
  # scripts/linux-switch.sh validates (sshd -t) before reloading.
  environment.etc."ssh/sshd_config.d/05-nix-hardening.conf".text = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes
  '';
}
