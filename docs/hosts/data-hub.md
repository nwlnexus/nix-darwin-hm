# data-hub runbook

`data-hub` is a Mac Studio (M1 Max, 64 GB, macOS 26) that runs headless as personal infrastructure. Since
olympus-sdk #701 it is compute like the Mac minis: the native macOS CI runner and the Tart k3s agent VM
`data-hub-vm` (8 vCPU, 32 GiB). It also serves two small llama-server instances (the coder-light fallback
behind the A9, and an embed fallback) and runs the atlas daemon. #701 retired its 27B instance and its Postgres.
The host file is `hosts/darwinM/data-hub.nix`. The runner and VM steps are in
[CI runner and Linux VM](#ci-runner-and-linux-vm).

The host still runs the nix-darwin 25.05 generation it got in September 2025 (built from the old `MACST-02.nix`)
on **Determinate Nix**. This repo now targets nix-darwin 26.05 on **upstream Nix**, and nix-darwin will not
activate on Determinate Nix, so the move is an uninstall and reinstall of Nix. The steps are below.

## What nix manages here, and what it does not

The profile captures the host's state. The mechanism that runs the services stays with Ansible (olympus-infra,
`inventory/data-hub.yml` and its `data_hub` group and host vars, applied hourly by ansible-pull) until atlas
replaces it.

nix-darwin manages:

- the `base` and `dev` profiles (CLI tools, `op` beta, Tailscale as the Homebrew formula), with no GUI profiles;
- the Homebrew packages the live services run from: `ansible`, `llama.cpp`, `ddclient`, `cloudflared`,
  `tailscale`;
- the native CI runner (`io.olympus.ci-runner`) and the k3s VM (`io.olympus.server-vm`), as on the minis;
- the host name, Remote Login (`services.openssh.enable`), and the power settings it has today: never sleep,
  restart after a power failure or a freeze, wake on network access;
- home-manager for the primary user, personal-only, with no 1Password desktop integration, no op-secrets and no
  memory-gateway client (none of those exist on the host today).

It does not manage, and leaves to Ansible:

| Item | Owner |
| --- | --- |
| `com.olympus.llama-server.{qwen25-7b,nomic-embed}` daemons, their wrappers, the GGUF models in `/opt/olympus/models`, the `llama.cpp` pin | Ansible `llama-server` role (push run for install and pin; pull run asserts) |
| `com.olympus.llama-server-watchdog` | Ansible `llama-server` role |
| Postgres retirement (#701: daemon booted out and deleted, `postgresql@16` uninstalled, data dir kept) | Ansible `data-services` role (push only) |
| `net.nwlnexus.atlas` and `net.nwlnexus.atlas-updater`, `/usr/local/bin/atlas`, the `_atlas` user | Ansible `atlas` role (atlas updates itself) |
| `com.olympus.ansible-pull`, `/opt/ansible-pull`, the `ansible` user | Ansible `ansible-pull` role |
| `net.nwlnexus.tailscale-watchdog` | Ansible `tailscale` role |
| `homebrew.mxcl.ddclient` and its config | Ansible `ddclient` role |
| Passwordless sudo for `nwilliams-lucas` and `ansible` (`/etc/sudoers.d/`) | set outside this repo (April 2026); the planned shared server role will own the user's entry |
| Screen Sharing, Remote Management, Remote Apple Events, SMB file sharing, Content Caching, application firewall (off), automatic login (on), FileVault (off) | set by hand; no repo option |

Homebrew cleanup is off on this host (`homebrew.onActivation.cleanup = "none"`): the first switch installs
what is declared and removes nothing. The leftovers below stay until the owner decides on them; then set cleanup
back to the fleet default by deleting that line.

## Audit (2026-10-31)

Taken read-only. Source: **nix** = the running 25.05 generation, **Ansible** = olympus-infra role, **manual** =
neither.

| Item | Source | State |
| --- | --- | --- |
| llama-server :8081 (qwen3.6-27b), :8082 (qwen2.5-7b), :8083 (nomic-embed), tailnet address only | Ansible `llama-server` | live |
| llama-server watchdog (every 60 s) | Ansible `llama-server` | live |
| Postgres 16 on :5432 (tailnet and loopback) | Ansible `data-services` | live (temporary, olympus-sdk #444 WS9) |
| atlas daemon and hourly updater | Ansible `atlas` | live |
| tailscaled (Homebrew formula, root LaunchDaemon) and tailscale-watchdog | Ansible `tailscale` | live |
| ansible-pull (hourly) | Ansible `ansible-pull` | loaded, **failing** since 2026-10-28: no route to github.com:443 |
| ddclient (root daemon) | Ansible `ddclient` | loaded |
| sshd :22 | macOS, Remote Login | live |
| Screen Sharing :5900, Remote Management :3283, Remote Apple Events :3031, SMB :445 | manual | live |
| Content Caching | manual | activated, idle |
| `socket_vmnet` root daemon | manual (Colima/Lima era) | running, nothing uses it: leftover |
| ddclient per-user LaunchAgent (duplicate of the root daemon) | manual | loaded: leftover |
| `homebrew.mxcl.ollama.plist.disabled`, `~/.ollama` | Ansible `ollama` (retired) | leftover |
| Cloudflare WARP cask, its daemon and `warp-cli` (disconnected) | nix 25.05 (`gui-full`) | daemon running: leftover; the `data-services` role uninstalls it on its next push run |
| `redis` formula, `clickhouse` cask, users `_redis`, `_clickhouse`, `_ollama` | Ansible `data-services` / `ollama` (retired) | leftover |
| `docker`, `docker-compose`, `docker-completion`, `docker-desktop` cask, `/usr/local/bin/orb*`, `~/.colima`, `~/.orbstack`, `~/.ssh/config` includes for both | manual | not running: leftover |
| `pgroll` (tap `xataio/pgroll`), taps `raggi/ale`, `redpanda-data/tap`, `cloudflare/cloudflare` | nix 25.05 / manual | leftover |
| `node`, `git`, `curl`, `wget`, `htop`, `tmux`, `tree`, `gnu-sed`, `bash`, `socat` formulae | manual | installed (nix provides most of these) |
| GUI casks: `1password` (stable), `angry-ip-scanner`, `cyberduck`, `google-chrome`, `jetbrains-toolbox`, `microsoft-remote-desktop`, `pandora`, `postman`, `raycast`, `scroll-reverser`, `slack`, `sublime-text`, `teamviewer`, `temurin`, `zed`, `zoom` | nix 25.05 (`gui-full`, `business`, `gui-small`) | installed: leftover on a headless host |
| `/opt/portainer`, `/opt/sentry`, `/opt/vibe-kanban`, `/opt/qnap-csi-plugin`, `/opt/platform` | manual | leftover |
| `~/nix-darwin-hm` (checkout from March 2026) | manual | leftover; the runbook uses `~/projects/personal/nix-darwin-hm` |
| `/etc/nix/nix.custom.conf` | Determinate installer | header comment only, no settings |
| Users beyond the defaults: `ansible`, `_atlas`, `_postgres` (live), `_redis`, `_clickhouse`, `_ollama` (leftover) | Ansible | see above |
| mise, asdf globals | none set (asdf is in the 25.05 system profile, unused) | none |
| home-manager | nix 25.05 | never activated: no managed dotfiles in the home directory |
| Claude Code | manual | `~/.claude` exists, no memory MCP server or hooks |

No live service depends on `/nix`: their wrappers and plists use `/opt/homebrew`, `/usr/local` and `/bin`, and
the login shell is `/bin/zsh`. Removing Nix therefore does not stop any service, which is what makes the
uninstall and reinstall below safe.

## Before you start

- **GitHub must be reachable from the host.** It was not from 2026-10-28 until the reboot of 2026-10-31 (about
  186,000 stale TIME_WAIT sockets had used up the ephemeral ports; olympus-sdk #697). Check:

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' https://github.com
  ```

- **Do not run this over Tailscale.** A switch can upgrade the `tailscale` formula and restart `tailscaled`,
  which drops a tailnet ssh session. Use the console, Screen Sharing over the LAN, or ssh to the LAN address.
- **No private input.** data-hub is a server (`d.server`): the private `olympus-sdk` input is neither fetched
  nor linked, so no GitHub key or agent forwarding is needed.
- **Optional hold.** To keep Ansible and the atlas updater out of the window, unload them for the duration and
  load them again at the end (step 9):

  ```sh
  sudo launchctl bootout system/com.olympus.ansible-pull
  sudo launchctl bootout system/net.nwlnexus.atlas-updater
  ```

## Steps

1. **Back up.** Keep a copy of the Nix config and of what is running, to compare afterwards. `nix.custom.conf`
   holds only the installer's header today, so there is nothing to carry over, but keep it anyway:

   ```sh
   mkdir -p ~/data-hub-migration
   cp /etc/nix/nix.conf /etc/nix/nix.custom.conf ~/data-hub-migration/
   sudo lsof -iTCP -sTCP:LISTEN -n -P > ~/data-hub-migration/listen.txt
   sudo launchctl list > ~/data-hub-migration/launchctl.txt
   brew list --formula -1 > ~/data-hub-migration/formulae.txt
   brew list --cask -1 > ~/data-hub-migration/casks.txt
   brew list --pinned > ~/data-hub-migration/pinned.txt
   pmset -g > ~/data-hub-migration/pmset.txt
   ```

2. **Clone the repo** to where the profile expects it:

   ```sh
   mkdir -p ~/projects/personal
   git clone https://github.com/nwlnexus/nix-darwin-hm.git ~/projects/personal/nix-darwin-hm
   cd ~/projects/personal/nix-darwin-hm
   ```

3. **Dry build on the current Nix.** Determinate Nix builds fine; only activation is refused. Build the new
   system as your user (this also proves the private input is reachable through the forwarded agent) and compare
   it with the running generation. `nvd` is not installed; run it from nixpkgs:

   ```sh
   nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- build --flake .#data-hub
   nix store diff-closures /run/current-system ./result
   nix run nixpkgs#nvd -- diff /run/current-system ./result
   ```

   Expect a large diff (25.05 to 26.05, and home-manager's first real activation). Look for anything that would
   touch the services above; there should be none. This build is only a rehearsal: step 5 deletes the store.

4. **Uninstall nix-darwin**, while its own uninstaller is still on disk. It restores the `/etc` files it replaced
   (`/etc/zshrc`, `/etc/zprofile`, `/etc/zshenv`, `/etc/bashrc`, `/etc/shells` from their `.before-nix-darwin`
   copies) and removes `org.nixos.activate-system`:

   ```sh
   sudo darwin-uninstaller
   ```

5. **Uninstall Determinate Nix.** This removes the `/nix` volume, `determinate-nixd` and the
   `systems.determinate.*` daemons:

   ```sh
   sudo /nix/nix-installer uninstall
   ```

   Then confirm nothing is left and the services are still up:

   ```sh
   ls /nix /Library/LaunchDaemons | grep -iE 'determinate|org.nixos'
   sudo lsof -iTCP -sTCP:LISTEN -n -P | grep -E ':(5432|8081|8082|8083) '
   ```

   If the uninstaller asks for a reboot, reboot: FileVault is off, so the host comes
   back by itself, and the services are LaunchDaemons that start at boot.

6. **Install upstream Nix and switch.** `install.sh` installs upstream Nix (`--prefer-upstream-nix`), builds the
   system as your user first (the private input, through the forwarded agent), then runs the first root switch
   with nix-darwin 26.05:

   ```sh
   cd ~/projects/personal/nix-darwin-hm
   NONINTERACTIVE=1 ./install.sh </dev/null
   ```

   If activation stops on the `nixbld` group id, set `ids.gids.nixbld` in the host file to the gid it names
   (350 today). home-manager activates for the first time and backs up files it takes over with a `.backup`
   suffix (for example `~/.ssh/config`, whose Colima and OrbStack includes it replaces).

7. **Later switches.** As your user, build first, then switch:

   ```sh
   just build
   just switch
   ```

8. **Check.**

   ```sh
   darwin-version
   nix --version
   ls /Library/LaunchDaemons | grep -iE 'determinate|org.nixos'
   sudo lsof -iTCP -sTCP:LISTEN -n -P | grep -E ':(22|5432|8081|8082|8083) '
   sudo launchctl list | grep -E 'olympus|nwlnexus|homebrew.mxcl'
   brew list --pinned
   sudo brew services list
   pmset -g | grep -E '^ *(sleep|autorestart|womp) '
   for s in getcomputersleep getrestartpowerfailure getrestartfreeze getwakeonnetworkaccess getremotelogin; do sudo systemsetup -$s; done
   ```

   Expect: a 26.05 `darwin-version`; `nix --version` without "Determinate"; only `org.nixos.*` daemons from the
   new install; sshd on :22, Postgres on :5432 and llama-server on :8081 to :8083 as in
   `~/data-hub-migration/listen.txt`; `com.olympus.postgres`, the three `com.olympus.llama-server.*` and
   `net.nwlnexus.atlas` with a PID; `llama.cpp` still pinned; tailscale `started` as `root`; `sleep 0`,
   `autorestart 1`, `womp 1`. Compare `brew list --formula -1` with `formulae.txt`: nothing should be missing
   (cleanup is off), and new entries are the profile's (`gh`, `qemu`, `pipx`, `kubecm`, `flyctl` and so on).

   If `llama.cpp` was upgraded despite the pin, the llama-server role's version assertion fails on the next pull
   run: reinstall the pinned version with the role's push run.

9. **Release the hold** if you took it:

   ```sh
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.olympus.ansible-pull.plist
   sudo launchctl bootstrap system /Library/LaunchDaemons/net.nwlnexus.atlas-updater.plist
   ```

## CI runner and Linux VM

The same modules as on the minis (`system/darwin/server-ci-runner.nix`, `system/darwin/server-linux-vm.nix`). Their
one-time steps are the ones in [mmini-01.md](mmini-01.md#one-time-steps-owner), with `data-hub` for `mmini-01`:

1. The GitHub App credentials in `/var/root/ci-runner/` (root-only).
2. The Ansible public key in `/etc/server-vm/ansible.pub`.
3. `server-vm-provision` as the owner. It creates `data-hub-vm` at 8 vCPU / 32 GiB / 150 GB on `en0`.
4. A DHCP reservation for the MAC address it prints. Then the VM joins k3s through olympus-infra (inventory
   group `k3s_mac_agents`), like mmini-01-vm and mmini-02-vm.

The VM takes the memory the 27B instance used. Memory plan: macOS and the two small llama-server instances use
about 12 GB, the VM 32 GiB, and a runner job uses the rest.

## Rollback

- **Before step 4** nothing has changed on the host; delete `./result` and stop.
- **After the new switch**, roll back between 26.05 generations as usual:

  ```sh
  sudo darwin-rebuild --rollback
  ```

- **The 25.05 generation cannot come back** once step 5 has removed the store. It is also not needed for the
  host to work: no service depends on Nix, so a host with a failed or partial switch, or with no Nix at all,
  keeps serving. If the switch fails, fix the cause and rerun `just switch`. To leave Nix off the host
  entirely, run `sudo darwin-uninstaller` and `sudo /nix/nix-installer uninstall` again.

## Decisions (owner, 2026-10-31)

- Leftovers: all removed by hand (olympus-sdk #697), including the retired data-tier users. Homebrew cleanup
  stays off here anyway, because Ansible installs some of what the services run from.
- Server rules (H20): headless, CLI only, Tailscale as a system daemon (Ansible's, here), passwordless sudo.
  Automatic login is turned off after the migration. Screen Sharing stays as the recovery path.
- ddclient stays until the owner decides otherwise.
