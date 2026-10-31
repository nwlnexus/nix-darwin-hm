#!/usr/bin/env bash
# Runs the Tart Linux VM headless on a bridged NIC (d.server.linuxVm, olympus-sdk #694, H20). Started by the
# LaunchDaemon at boot. It waits until Tart is installed (the first `brew bundle` may still be running) and until
# `server-vm-provision` has hardened the VM, so the VM never joins the LAN with its image's default credentials.
# Environment: VM_NAME VM_BRIDGE VM_MARKER TART_BIN.
set -euo pipefail

: "${VM_NAME:?}" "${VM_BRIDGE:?}" "${VM_MARKER:?}" "${TART_BIN:?}"

waiting=0
while [ ! -x "$TART_BIN" ] || [ ! -e "$VM_MARKER" ]; do
  if [ "$waiting" -eq 0 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) waiting for $TART_BIN and $VM_MARKER (run server-vm-provision)"
    waiting=1
  fi
  sleep 30
done

exec "$TART_BIN" run --no-graphics "--net-bridged=$VM_BRIDGE" "$VM_NAME"
