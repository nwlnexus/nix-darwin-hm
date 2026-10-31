#!/usr/bin/env bash
# One-time, idempotent provisioning of the Tart Linux VM (server-vm-provision; d.server.linuxVm, olympus-sdk #694).
# Run it as the VM's owner, never as root. It does NOT run on a switch.
#
# The cirruslabs Ubuntu image ships a default login (admin/admin). So the VM is first booted on Tart's NAT network,
# which only this Mac can reach, and hardened there: an `ansible` user with the owner's public key and passwordless
# sudo, password logins off, only `ansible` may ssh in, `admin` locked. Only after that does it get its marker file;
# the LaunchDaemon waits for that marker before it first starts the VM on the bridged NIC.
#
# Environment: VM_NAME VM_CPUS VM_MEMORY_MB VM_DISK_GB VM_IMAGE VM_ANSIBLE_KEY_FILE VM_OWNER VM_MARKER TART_BIN.
set -euo pipefail

: "${VM_NAME:?}" "${VM_CPUS:?}" "${VM_MEMORY_MB:?}" "${VM_DISK_GB:?}" "${VM_IMAGE:?}"
: "${VM_ANSIBLE_KEY_FILE:?}" "${VM_OWNER:?}" "${VM_MARKER:?}" "${TART_BIN:?}"

say() { printf 'server-vm-provision: %s\n' "$*" >&2; }
die() {
  say "$*"
  exit 1
}

[ "$(id -un)" = "$VM_OWNER" ] || die "run this as $VM_OWNER (the VM lives in that user's TART_HOME), not as $(id -un)"
[ -x "$TART_BIN" ] || die "$TART_BIN is missing; the first darwin-rebuild switch installs Tart through Homebrew"
[ -r "$VM_ANSIBLE_KEY_FILE" ] || die "put the ansible public key in $VM_ANSIBLE_KEY_FILE"
ssh-keygen -l -f "$VM_ANSIBLE_KEY_FILE" >/dev/null 2>&1 || die "$VM_ANSIBLE_KEY_FILE is not a valid ssh public key"
[ "$(grep -c . "$VM_ANSIBLE_KEY_FILE")" -eq 1 ] || die "$VM_ANSIBLE_KEY_FILE must hold exactly one public key"

tart_home=${TART_HOME:-$HOME/.tart}
config="$tart_home/vms/$VM_NAME/config.json"
mac() { jq -er .macAddress "$config"; }

report() {
  say "VM $VM_NAME is provisioned."
  say "MAC address: $(mac)"
  say "Add a DHCP reservation for that MAC on the .253 network, then the VM comes up with its LaunchDaemon."
}

if [ -e "$VM_MARKER" ]; then
  report
  exit 0
fi

work=$(mktemp -d)
vm_log="$work/tart-run.log"
askpass="$work/askpass.sh"
vm_pid=""
cleanup() {
  if [ -n "$vm_pid" ]; then
    "$TART_BIN" stop "$VM_NAME" --timeout 60 >/dev/null 2>&1 || true
    wait "$vm_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# An interrupted earlier run may have left the VM running.
"$TART_BIN" stop "$VM_NAME" --timeout 30 >/dev/null 2>&1 || true

if "$TART_BIN" list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
  say "VM $VM_NAME exists but was never marked provisioned; resuming at the hardening step."
else
  say "cloning $VM_IMAGE as $VM_NAME (this pulls the image)"
  "$TART_BIN" clone "$VM_IMAGE" "$VM_NAME"
  "$TART_BIN" set "$VM_NAME" --cpu "$VM_CPUS" --memory "$VM_MEMORY_MB" --disk-size "$VM_DISK_GB"
  "$TART_BIN" set "$VM_NAME" --random-mac
fi
say "VM MAC address (kept from now on): $(mac)"

# The image's default login is public knowledge, and it is only ever offered on Tart's NAT network.
printf '#!/bin/sh\necho admin\n' >"$askpass"
chmod 700 "$askpass"

ssh_admin() {
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=10 "admin@$ip" "$@"
}

say "booting $VM_NAME on Tart's NAT network (not bridged)"
"$TART_BIN" run --no-graphics "$VM_NAME" >"$vm_log" 2>&1 &
vm_pid=$!

ip=""
for _ in $(seq 1 60); do
  kill -0 "$vm_pid" 2>/dev/null || die "tart run exited early: $(tail -n 5 "$vm_log")"
  ip=$("$TART_BIN" ip "$VM_NAME" --wait 5 2>/dev/null || "$TART_BIN" ip "$VM_NAME" --resolver=arp --wait 1 2>/dev/null || true)
  [ -n "$ip" ] && break
done
[ -n "$ip" ] || die "the VM did not get an address on the NAT network"

for _ in $(seq 1 60); do
  ssh_admin true 2>/dev/null && break
  sleep 5
done
ssh_admin true || die "cannot ssh to the VM as admin on the NAT network (is this a cirruslabs image?)"

key=$(cat "$VM_ANSIBLE_KEY_FILE")
fingerprint=$(ssh-keygen -l -f "$VM_ANSIBLE_KEY_FILE" | awk '{ print $2 }')
say "hardening the VM"
ssh_admin "sudo env KEY=$(printf '%q' "$key") FP=$(printf '%q' "$fingerprint") NAME=$(printf '%q' "$VM_NAME") bash -s" <<'REMOTE'
set -eu

# The image boots as `ubuntu`; the node (and its k3s name) must be the VM's own name.
hostnamectl set-hostname "$NAME"
sed -i "s/\bubuntu\b/$NAME/g" /etc/hosts

id ansible >/dev/null 2>&1 || useradd --create-home --shell /bin/bash ansible
install -d -m 0700 -o ansible -g ansible /home/ansible/.ssh
printf '%s\n' "$KEY" >/home/ansible/.ssh/authorized_keys
chown ansible:ansible /home/ansible/.ssh/authorized_keys
chmod 0600 /home/ansible/.ssh/authorized_keys
test "$(ssh-keygen -l -f /home/ansible/.ssh/authorized_keys | awk '{ print $2 }')" = "$FP"
printf 'ansible ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-ansible
chmod 0440 /etc/sudoers.d/90-ansible
visudo -cf /etc/sudoers.d/90-ansible >/dev/null

cat >/etc/ssh/sshd_config.d/00-server-vm.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ansible
CONF
sshd -t
systemctl try-reload-or-restart ssh || true
test "$(sshd -T | awk '$1 == "passwordauthentication" { print $2 }')" = no

# The router matches a DHCP reservation on the MAC; Ubuntu's default client id is a DUID, which would miss it.
nic=$(netplan get ethernets 2>/dev/null | sed -n 's/^\([A-Za-z0-9_.-]*\):$/\1/p' | head -n 1)
if [ -n "$nic" ]; then
  netplan set "ethernets.$nic.dhcp-identifier=mac" || echo "warning: could not set dhcp-identifier" >&2
else
  echo "warning: no netplan ethernet found; check the DHCP client id by hand" >&2
fi

# Grow the root filesystem to the resized disk (best effort; the image may already do it at boot).
root=$(findmnt -no SOURCE /)
disk="/dev/$(lsblk -no pkname "$root")"
part=$(cat "/sys/class/block/$(basename "$root")/partition")
growpart "$disk" "$part" >/dev/null 2>&1 || true
resize2fs "$root" >/dev/null 2>&1 || true

passwd -l admin >/dev/null
usermod --expiredate 1 --shell /usr/sbin/nologin admin
passwd -S admin | awk '{ exit ($2 == "L" ? 0 : 1) }'

# Flush to disk before the VM is stopped: without this the files written above came back zero-length after
# the stop (ext4 delayed allocation), which left the VM with no ansible key, no sudo rule and password login on.
sync
test -s /home/ansible/.ssh/authorized_keys
test -s /etc/sudoers.d/90-ansible
test -s /etc/ssh/sshd_config.d/00-server-vm.conf
REMOTE

if ssh_admin true 2>/dev/null; then
  die "admin can still log in with the default password; not marking the VM provisioned"
fi
say "admin password login is refused"

"$TART_BIN" stop "$VM_NAME" --timeout 60 || true
wait "$vm_pid" 2>/dev/null || true
vm_pid=""

mkdir -p "$(dirname "$VM_MARKER")"
date -u +%Y-%m-%dT%H:%M:%SZ >"$VM_MARKER"
report
