{ config, ... }:
{
  # IEEE 802.1ab (LLDP) daemon — announces this host to switches/neighbors.
  # Formula is homebrew-core (implicitly trusted). The service requires root
  # (`require_root`), but nix-darwin's brew bundle runs as the primary user, so
  # Brewfile `start_service`/`restart_service` only warn and never load the
  # boot daemon. Start it from postActivation (runs as root, after brew install).
  homebrew.brews = [ "lldpd" ];

  system.activationScripts.postActivation.text = ''
    echo "starting lldpd (brew services)..." >&2
    brew="${config.homebrew.prefix}/bin/brew"
    if [ -x "$brew" ] && "$brew" list --formula lldpd >/dev/null 2>&1; then
      "$brew" services start lldpd >/dev/null 2>&1 \
        || "$brew" services restart lldpd \
        || echo >&2 "warning: failed to start lldpd via brew services"
    fi
  '';
}
