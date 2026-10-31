# dtlr-ai-agent-host runbook

`dtlr-ai-agent-host` is a work-only Mac Studio agent host. It runs like `ai-agent-host`: headless-capable, Claude
Code and Codex Remote Control, tmux and the CLI, for one account, `work`, rooted at `~/projects/work`. The host file
is `hosts/darwinM/dtlr-ai-agent-host.nix`.

## What "work-only" means here

`d.workOnly.enable = true` (`system/darwin/work-only.nix` and `home/work-only.nix`) evaluates none of the personal
configuration:

- op-secrets reads only the work 1Password account (`d.apps.onepassword.allowedAccounts`), with the work
  service-account token file. There is no personal token, no personal ssh key, no `personal-env` and no
  `op-connect-env`.
- No memory-gateway client (`d.memory.enable = false`, asserted).
- No second-brain: no checkout, no pull agent, no `/brain` command, and no `SECOND_BRAIN_PATH`.
- The Claude harness keeps the generic agents, hooks, skills and allow rules. It has no autoMode source and no
  telemetry source (`d.claudeHarness.settings.autoModeFile = null`, `d.claudeHarness.telemetry.file = null`):
  both come from a private input that carries the personal environment, so `.autoMode` in
  `~/.claude-work/settings.json` is left as Claude Code writes it. To give this host its own auto-mode rules,
  point `autoModeFile` at a work file (format: `home/cli/claude/auto-mode.nix`).
- Git uses the work identity everywhere and signs with `~/.ssh/gitlab-work-gl`, with no personal include. The ssh
  config has no personal GitHub, homelab or tailnet blocks.
- The private `olympus-sdk` flake input is never fetched or linked, so the host needs no access to it.
  `just test-work-only-private-input` proves it, and `tests/work-only.nix` (`just test`) asserts the rest.

Tailscale is the Homebrew formula, run as a root LaunchDaemon, never the app cask
(`d.profiles.base.tailscale = "formula"`). Power settings are server-like (`power.*`, `networking.wakeOnLan`).

Toggles in the host file, one line each: `gui-full.enable` (the Desktop app and the 1Password app; off, CLI-only)
and `accounts.work.remoteControl.codex` (on; set `false` if Codex is not used here).

## Bootstrap

Run these as the primary user, in order. Steps 4 and 5 must come before the first `darwin-rebuild`.

1. **macOS.** Finish setup with the primary user account, and decide FileVault (see "FileVault and unattended
   reboots" below).

2. **Hostname.** The flake picks the host by `LocalHostName`:

   ```sh
   sudo scutil --set ComputerName dtlr-ai-agent-host
   sudo scutil --set HostName dtlr-ai-agent-host
   sudo scutil --set LocalHostName dtlr-ai-agent-host
   ```

3. **Nix, Homebrew and first switch.** Clone this public repo over HTTPS (no key needed yet), outside the work tree,
   then run the installer. It installs Homebrew and upstream Nix (not Determinate, which nix-darwin refuses),
   checks the hostname matches `hosts/darwinM/<name>.nix`, and runs the first `sudo ... darwin-rebuild switch`. If
   it reports Determinate Nix, run `sudo /nix/nix-installer uninstall` and rerun it:

   ```sh
   mkdir -p ~/projects/personal
   git clone https://github.com/nwlnexus/nix-darwin-hm.git ~/projects/personal/nix-darwin-hm
   cd ~/projects/personal/nix-darwin-hm && ./install.sh
   ```

4. **Work 1Password token.** Write the work service-account token, the raw token value only, to
   `~/.config/work/1penv` (mode 0600). op-secrets reads it on every switch. The service account needs read access
   to the vault that `home/secrets/work-env.tpl` reads.

   With the token on the clipboard:

   ```sh
   install -d -m 700 ~/.config/work
   ( umask 077 && pbpaste > ~/.config/work/1penv )
   chmod 600 ~/.config/work/1penv
   ```

5. **Work GitHub ssh key.** Put the work GitHub key at `~/.ssh/gitlab-work-gl` (0600) with its public half at
   `~/.ssh/gitlab-work-gl.pub`. Take it from the work 1Password account. It is both the GitHub auth key (through the
   `github.com-work` alias) and the commit-signing key, so add it to the work GitHub account as an authentication
   key and as a signing key.

6. **Later switches.** `install.sh` ran the first switch in step 3. To apply later changes (or after adding the token and key from steps 4 and 5), switch again. The host does not need the private `olympus-sdk` input, so no `just build` first is needed
   (that step only exists for hosts that fetch private inputs over ssh):

   ```sh
   cd ~/projects/personal/nix-darwin-hm
   sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#dtlr-ai-agent-host
   ```

   After that, `just switch`. If activation stops on the `nixbld` group id, set `ids.gids.nixbld` in the host
   file to the gid it reports.

7. **Tailscale.** Run the formula as a root LaunchDaemon (brew names it `/Library/LaunchDaemons/sh.brew.tailscale.plist`,
   older brew `homebrew.mxcl.tailscale.plist`), started at boot, matching data-hub. Only one `tailscaled` may run:
   if an earlier `tailscaled install-system-daemon` set one up (`com.tailscale.tailscaled`, binary in
   `/usr/local/bin`), the brew service crash-loops with `safesocket.Listen: ... address already in use`
   (`/opt/homebrew/var/log/tailscaled.log`). Remove it first; both use `/Library/Tailscale` as state, so the node
   keeps its identity, tag and key-expiry setting. If it ran as a per-user brew service, stop that too:

   ```sh
   sudo /usr/local/bin/tailscaled uninstall-system-daemon
   brew services stop tailscale
   sudo brew services start tailscale
   sudo brew services list
   sudo tailscale status
   ```

   (`uninstall-system-daemon` fails harmlessly when there is no such daemon.) If the root daemon has no state yet,
   run `sudo tailscale up` once and approve it. Then apply the work agent-host tag in the admin console, and
   disable key expiry there too: tagging a node that already joined keeps its existing expiry. A switch can
   upgrade the formula and restart the daemon, so don't run `darwin-rebuild` over a Tailscale ssh session you
   can't lose.

8. **Work repos.** Clone into `~/projects/work`. Use `git@github.com:<org>/<repo>.git` URLs: git rewrites them to
   the `github.com-work` alias.

9. **Native Claude Code and Codex.** The `claude-work`/`codex-work` launchers and the Remote Control daemons run the
   native installs in `~/.local/bin` (as on the Linux agent host); nix does not install them:

   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   curl -fsSL https://chatgpt.com/codex/install.sh | sh
   ls -l ~/.local/bin/claude ~/.local/bin/codex
   ```

   Both update themselves; `agents restart` picks up a new version.

10. **Claude Code, work login.** Run `claude-work` inside `~/projects/work`, accept the trust prompt, then
   `/login` with the work account. The `claude-rc-work` LaunchDaemon (runs as you, starts at boot) waits for that login and then starts Remote
   Control; the session shows on claude.ai under the work login.

    Then accept Remote Control once, interactively: the first `remote-control` run asks
    `Enable Remote Control? (y/n)`, which the background agent cannot answer (it exits and restarts in a loop,
    visible in `~/Library/Logs/agent-host/claude-rc-work.log`). Answer `y`, wait for `Connected`, press Ctrl+C,
    then hand it back to the daemon:

    ```sh
    cd ~/projects/work
    claude-work remote-control
    agents restart claude-rc-work
    ```

    The environment then shows on claude.ai (signed into the work account) for this host.

11. **Codex (if used).** `codex-work login --device-auth`.

12. **Checks.**

    Expect `claude-rc-work` (and `codex-rc-work`) running; `sleep 0`, `disksleep 0`, `autorestart 1`, `womp 1`;
    and tailscale `started` as `root`:

    ```sh
    agents status
    pmset -g | grep -E '^ *(sleep|disksleep|autorestart|womp) '
    for s in getcomputersleep getrestartpowerfailure getwakeonnetworkaccess; do sudo systemsetup -$s; done
    sudo brew services list | grep tailscale
    ```

    nix-darwin applies the power settings with `systemsetup` on every switch. If `pmset -g` disagrees, set them by
    hand with `sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1` and report the mismatch.

13. **No personal files.** None of these may exist:

    ```sh
    ls -la ~/.config/personal ~/.ssh/id_ed25519 ~/projects/personal/.env ~/projects/personal/.op-connect \
      ~/projects/personal/.envrc ~/.config/memory ~/.local/share/second-brain 2>&1 | grep -v 'No such file'
    ```

    The output should be empty.

## FileVault and unattended reboots (owner decision)

FileVault is off on this host. Remote Control runs as system LaunchDaemons (`io.olympus.agent-host.claude-rc-work`
and `codex-rc-work`, running as the primary user), so after a power cut or reboot the Mac powers back on
(`autorestart 1`) and the services start with nobody logged in. Automatic login is not set. The cost is an
unencrypted disk at rest.

### Keychain caveat and boot test

Claude Code on macOS stores its OAuth token in the login Keychain, which is locked until a GUI login. The daemon's
`logged_in` check passes on `oauthAccount` in `~/.claude-work/.claude.json`, but `claude remote-control` may still
be unable to read the token with no GUI session.

Test after the switch:

1. Log out of the GUI (or just reboot; nobody logs in), then reboot:

   ```sh
   sudo shutdown -r now
   ```

2. Wait a few minutes, then ssh in (over Tailscale) without ever logging in at the console:

   ```sh
   agents status
   tail -n 50 ~/Library/Logs/agent-host/claude-rc-work.log
   ```

   Pass: `claude-rc-work` is `running` and the log shows Remote Control connected/serving, and the environment is
   online on claude.ai. Fail: a keychain, `errSecInteractionNotAllowed`, "not logged in" or auth error, or a
   restart loop.

3. If it fails, log in over ssh with no GUI session, where Claude Code falls back to
   `~/.claude-work/.credentials.json` (0600), as on the Linux agent host:

   ```sh
   cd ~/projects/work
   claude-work
   ```

   Run `/login` inside it, finish the browser step on another device, exit, then:

   ```sh
   ls -l ~/.claude-work/.credentials.json
   agents restart claude-rc-work
   tail -n 20 ~/Library/Logs/agent-host/claude-rc-work.log
   ```

   Repeat the reboot test. This repo adds no token file, `setup-token` flow or auto-login.
