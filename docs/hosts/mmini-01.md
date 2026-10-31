# mmini-01 first-boot runbook

`mmini-01` is a Mac mini M4 Pro run as a headless cluster server (olympus-sdk #694, H20). The host file is
`hosts/darwinM/mmini-01.nix`; it sets `d.server.enable` and nothing else personal (see "Server hosts (d.server)" in
`AGENTS.md`). It replaces `NWL-MMINI`, the retired workstation of the same machine. It also runs a native
ephemeral CI runner and a Tart Linux VM (below); atlas arrives in a later PR.

This runbook takes a factory-fresh Mac to a running server. Run it as the owner. Nothing here is automated, and
nothing in this repo switches a machine for you.

## What the role gives you

- No GUI profiles, no iTerm2 or Obsidian, no memory client, no second-brain, no personal tokens.
- The Homebrew `tailscaled` as a system daemon, `com.tailscale.tailscaled`, that starts at boot with nobody logged in.
- Never sleeps, restarts after a power failure or a freeze, wakes on LAN.
- Remote Login (sshd) on at boot.
- Passwordless sudo for the owner's account only.
- No auto-login, and no LaunchAgent that the role adds.

Not managed by nix: Screen Sharing, and FileVault. FileVault stays off on the minis so that they come back by
themselves after a power cut; an unattended reboot would otherwise stop at the unlock screen. They hold CI scratch,
the runner's App key and atlas and Tailscale state, all of which can be revoked.

## First boot

1. **Setup Assistant.** Finish it with the owner's account (`nwilliams-lucas`, an administrator). Leave FileVault
   off. Do not enable auto-login.

2. **Remote Login, the one GUI step.** In System Settings, open General, then Sharing, and turn on Remote Login for
   the owner's account. Everything after this runs over ssh from another machine, or on the console. Find the mini's
   address in your router or with `ipconfig getifaddr en0` on the mini, then:

   ```sh
   ssh nwilliams-lucas@mmini-01.local
   ```

   The mDNS name works only after step 4; until then use the address.

3. **Command Line Tools without the GUI.** Homebrew and git need them. Creating the marker file makes
   `softwareupdate` list the tools; the second command picks the newest listed label and installs it, and the
   third removes the marker:

   ```sh
   touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
   label="$(softwareupdate --list 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | tail -n 1)"
   sudo softwareupdate --install "$label" --verbose
   rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
   xcode-select -p
   ```

   `xcode-select -p` must print `/Library/Developer/CommandLineTools`. If `$label` came out empty, run
   `softwareupdate --list` and read the label by eye.

4. **Names.** The flake picks the host config by `LocalHostName`, and the name must match the file name exactly:
   `mmini-01`, lowercase. Set all three names:

   ```sh
   sudo scutil --set ComputerName mmini-01
   sudo scutil --set LocalHostName mmini-01
   sudo scutil --set HostName mmini-01
   scutil --get LocalHostName
   ```

5. **Clone the repo.** It is public, so HTTPS needs no key:

   ```sh
   mkdir -p ~/projects/personal
   git clone https://github.com/nwlnexus/nix-darwin-hm.git ~/projects/personal/nix-darwin-hm
   ```

6. **Install and first switch.** `install.sh` installs Homebrew and upstream Nix (nix-darwin refuses Determinate
   Nix), checks that `hosts/darwinM/mmini-01.nix` exists for this name, builds the configuration as your user, then
   does the first `sudo` switch. The password prompt is the last you will need: after the switch, sudo does not ask.
   If it reports Determinate Nix, run `sudo /nix/nix-installer uninstall` and start `./install.sh` again.

   ```sh
   cd ~/projects/personal/nix-darwin-hm
   ./install.sh
   ```

   This host needs no ssh key: the private `olympus-sdk` input is not fetched. If activation stops on the `nixbld`
   group id, set `ids.gids.nixbld` in `hosts/darwinM/mmini-01.nix` to the gid it reports. Later changes:

   ```sh
   cd ~/projects/personal/nix-darwin-hm
   just switch
   ```

7. **Join the tailnet.** The daemon is already running from the switch. Join without Tailscale ssh; open the URL it
   prints in a browser and approve the node. The ACL tag is added later in the admin console, and key expiry should
   be disabled there too (tagging a node that already joined keeps its existing expiry):

   ```sh
   sudo tailscale up --ssh=false
   tailscale status
   ```

   Do not run `sudo brew services start tailscale`: the LaunchDaemon from the switch is the one daemon.

## Check that it survives a reboot with nobody logged in

Reboot, and do not log in on the console. FileVault is off, so the Mac boots to the login window by itself:

```sh
sudo shutdown -r now
```

After a minute or two, ssh in again from another machine. Remote Login coming back is the first check:

```sh
ssh nwilliams-lucas@mmini-01
```

Then confirm the rest:

```sh
stat -f '%Su' /dev/console
sudo -n true && echo sudo-ok
sudo launchctl print system/com.tailscale.tailscaled | grep -E 'state|pid'
tailscale status
pmset -g | grep -E '^ *(sleep|displaysleep|disksleep|autorestart|womp) '
```

Expect:

- `root` from the first command: no user owns the console, so nobody is logged in.
- `sudo-ok`, with no password prompt.
- the Tailscale job `state = running` with a `pid`, and `tailscale status` listing the node as connected.
- `sleep 0`, `displaysleep 0`, `disksleep 0`, `autorestart 1` and `womp 1`.

If the Tailscale job is not running, read `/var/log/tailscaled.log`. If `pmset -g` disagrees, run
`sudo pmset -a sleep 0 displaysleep 0 disksleep 0 autorestart 1 womp 1` and report the mismatch. To test the power
loss path, pull the power cable and plug it back in; the mini should start by itself.

## CI runner and Linux VM

`hosts/darwinM/mmini-01.nix` turns on `d.server.ciRunner` (`system/darwin/server-ci-runner.nix`) and
`d.server.linuxVm` (`system/darwin/server-linux-vm.nix`) with their defaults. The switch installs both LaunchDaemons
and Tart. Neither does anything useful until the owner has done the one-time steps below; both wait quietly for them
(they never run with partial credentials).

### What they are

- **Runner**: `io.olympus.ci-runner`, a root LaunchDaemon looping one job at a time. For each job it signs a JWT
  with the GitHub App key, gets an installation token, resolves the runner group `olympus-ci` in `nwlnexus`, asks
  for a just-in-time config for a runner named `mmini-01-<timestamp>` with labels
  `self-hosted, macOS, ARM64, macos-arm64`, and runs the pinned official `actions/runner` as the hidden user
  `_ghrunner` (uid 533, no shell, not an admin, not in sudoers, home under `/var/lib/ci-runner`), under `nice -n 10`.
  The JIT config reaches the runner in its environment (`ACTIONS_RUNNER_INPUT_JITCONFIG`), never on a command
  line. After the job the loop kills the user's processes, deletes its home and runner copy and its files in
  `/private/tmp`, and starts again. Errors back off from 30 s to 5 min. The App key stays root-only; the runner user
  never sees it. Log: `/var/log/ci-runner.log`.
- **VM**: `io.olympus.server-vm`, a LaunchDaemon that runs `tart run --no-graphics --net-bridged=en0 mmini-01-vm`
  at boot with nobody logged in, KeepAlive, as the owner's account (see `system/darwin/server-linux-vm.nix` for why
  not root). Ubuntu 24.04 arm64 from `ghcr.io/cirruslabs/ubuntu:24.04`, 6 vCPU, 12 GiB, 150 GB. It starts only
  once `server-vm-provision` has written `~/.tart/mmini-01-vm.provisioned`. Log: `/var/log/server-vm.log`.
- **Memory**: the mini has 24 GB. The VM holds 12 GiB, the rest is macOS, Tailscale and one runner job at a time.
  A job that needs more than about 8 GB will push the host into swap; keep memory-heavy jobs on the cluster.

### One-time steps (owner)

1. **GitHub App credentials.** Create the App's private key in the GitHub App settings (the App needs
   organization permission Self-hosted runners: read and write, installed on `nwlnexus`), and create the runner group
   `olympus-ci` in the organization. Copy the key to the mini by a route you trust (not into this repo, not a chat),
   then install the three files as root-only (the directory is 0700, so the briefly looser mode `tee` creates is not reachable). `<APP_ID>` and `<INSTALLATION_ID>` are the numbers from the App
   settings page and the installation URL:

   ```sh
   sudo install -d -m 0700 -o root -g wheel /var/root/ci-runner
   printf '%s\n' '<APP_ID>' | sudo tee /var/root/ci-runner/app-id >/dev/null
   printf '%s\n' '<INSTALLATION_ID>' | sudo tee /var/root/ci-runner/installation-id >/dev/null
   sudo chmod 0400 /var/root/ci-runner/app-id /var/root/ci-runner/installation-id
   sudo install -m 0400 -o root -g wheel /path/to/downloaded-key.pem /var/root/ci-runner/private-key.pem
   rm -P /path/to/downloaded-key.pem
   ```

   The loop refuses a file that is not owned by root or is readable by anyone else. Within a minute it registers a
   runner; no restart is needed.

2. **Ansible public key.** The VM's only login is an `ansible` user with this key. Put one public key line in place
   (the key itself, not a private key):

   ```sh
   sudo install -d -m 0755 /etc/server-vm
   printf '%s\n' '<ANSIBLE_PUBLIC_KEY_LINE>' | sudo tee /etc/server-vm/ansible.pub >/dev/null
   ```

3. **Provision the VM.** As the owner (not with sudo). It pulls the image, sizes the VM, boots it on Tart's NAT
   network (the image ships `admin`/`admin`, reachable only from this Mac), creates `ansible` with the key and
   passwordless sudo, turns off ssh password logins, allows only `ansible` to ssh in, locks `admin`, checks that the
   `admin` password no longer works, shuts the VM down and writes the marker. It is safe to run again: with the
   marker present it only prints the MAC address. If it stops on a Keychain error over ssh, run
   `security unlock-keychain login.keychain` once and run it again.

   ```sh
   server-vm-provision
   ```

4. **DHCP reservation.** The script prints `MAC address: ...` (it is also `macAddress` in
   `~/.tart/vms/mmini-01-vm/config.json`; Tart keeps it for the life of the VM). Add a DHCP reservation for that MAC
   on the .253 network in the router. Within about 30 s of the marker the LaunchDaemon starts the VM on `en0`; if
   the reservation came later, restart the VM so it asks again:

   ```sh
   sudo launchctl kickstart -k system/io.olympus.server-vm
   ```

   The VM joins k3s as an agent through Ansible, from the cluster repo; nothing in this repo does that.

### Checks

Both daemons loaded, and the runner user is unprivileged:

```sh
sudo launchctl print system/io.olympus.ci-runner | grep -E 'state|pid'
sudo launchctl print system/io.olympus.server-vm | grep -E 'state|pid'
id _ghrunner
dscl . -read /Users/_ghrunner IsHidden UserShell
sudo -l -U _ghrunner
dseditgroup -o checkmember -m _ghrunner admin
```

Expect `uid=533(_ghrunner)`, `IsHidden: 1`, `UserShell: /usr/bin/false`, "not allowed to run sudo" and "no, _ghrunner is NOT a member of admin".

The runner registered, and the credentials are closed:

```sh
sudo tail -n 20 /var/log/ci-runner.log
sudo stat -f '%Su %Lp %N' /var/root/ci-runner/*
sudo -u _ghrunner cat /var/root/ci-runner/private-key.pem
ps -axo user,args | grep -i jitconfig
```

Expect `registered runner mmini-01-<timestamp> in group olympus-ci`, `root 400` for all three files, a permission
error for the `_ghrunner` read, and no `jitconfig` in `ps` output. In the organization settings, one idle runner
named `mmini-01-...` is in `olympus-ci`; a job with `runs-on: [self-hosted, macos-arm64]` runs, and afterwards that
runner is gone and a new one has taken its place. Check the wipe after a job: `sudo ls -A /var/lib/ci-runner/home`
shows only `tmp`.

The VM is up, headless and bridged:

```sh
tart list
sudo tail -n 20 /var/log/server-vm.log
ssh -o PasswordAuthentication=no ansible@<VM_ADDRESS> hostname
ssh -o PubkeyAuthentication=no admin@<VM_ADDRESS> true
ssh ansible@<VM_ADDRESS> 'uname -m; nproc; free -g; df -h /'
```

Expect `mmini-01-vm` running in `tart list`, the address you reserved for `<VM_ADDRESS>`, the first ssh printing the
VM's hostname, the second refused, and `aarch64`, 6 CPUs, about 12 GiB and about 150 GB. Reboot the mini with nobody
logged in and repeat the first check: the VM must come back by itself.

If the VM daemon loops with a Virtualization.framework error in `/var/log/server-vm.log`, that is the part of this
design that was not verified on hardware (a LaunchDaemon with `UserName` and no GUI session). Report the exact error
before changing anything; the fallback is to run the same command as a LaunchAgent with auto-login, which this role
otherwise avoids.

## Later

atlas is added to `hosts/darwinM/mmini-01.nix` by a later PR for olympus-sdk #694. The mini moves to the .253 network once set up (H20).
