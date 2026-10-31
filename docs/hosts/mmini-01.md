# mmini-01 first-boot runbook

`mmini-01` is a Mac mini M4 Pro run as a headless cluster server (olympus-sdk #694, H20). The host file is
`hosts/darwinM/mmini-01.nix`; it sets `d.server.enable` and nothing else personal (see "Server hosts (d.server)" in
`AGENTS.md`). It replaces `NWL-MMINI`, the retired workstation of the same machine. The runner, the Tart VM and
atlas arrive in later PRs.

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
   touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress-file
   label="$(softwareupdate --list 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | tail -n 1)"
   sudo softwareupdate --install "$label" --verbose
   rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress-file
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

## Later

The macOS runner, the Tart VM (`mmini-01-vm`) and atlas are added to `hosts/darwinM/mmini-01.nix` by later PRs for
olympus-sdk #694. The mini moves to the .253 network once set up (H20).
