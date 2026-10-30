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

3. **Nix and Homebrew.** Clone this public repo over HTTPS (no key needed yet), outside the work tree, then run the
   installer:

   ```sh
   git clone https://github.com/nwlnexus/nix-darwin-hm.git ~/nix-darwin-hm
   cd ~/nix-darwin-hm && ./install.sh
   ```

4. **Work 1Password token.** Write the work service-account token, the raw token value only, to
   `~/.config/work/1penv` (mode 0600). op-secrets reads it on every switch. The service account needs read access
   to the vault that `home/secrets/work-env.tpl` reads.

   ```sh
   install -d -m 700 ~/.config/work
   ( umask 077 && pbpaste > ~/.config/work/1penv )   # with the token on the clipboard
   chmod 600 ~/.config/work/1penv
   ```

5. **Work GitHub ssh key.** Put the work GitHub key at `~/.ssh/gitlab-work-gl` (0600) with its public half at
   `~/.ssh/gitlab-work-gl.pub`. Take it from the work 1Password account. It is both the GitHub auth key (through the
   `github.com-work` alias) and the commit-signing key, so add it to the work GitHub account as an authentication
   key and as a signing key.

6. **First switch.** The host does not need the private `olympus-sdk` input, so no `just build` first is needed
   (that step only exists for hosts that fetch private inputs over ssh):

   ```sh
   cd ~/nix-darwin-hm
   sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#dtlr-ai-agent-host
   ```

   After that, `just switch`. If activation stops on the `nixbld` group id, set `ids.gids.nixbld` in the host
   file to the gid it reports.

7. **Tailscale.** Run the formula as a root LaunchDaemon (`/Library/LaunchDaemons/homebrew.mxcl.tailscale.plist`),
   started at boot:

   ```sh
   brew services stop tailscale 2>/dev/null || true   # only if it ran as a per-user service before
   sudo brew services start tailscale
   sudo tailscale status
   ```

   If the node was joined from a per-user daemon, the root daemon starts with its own state: run
   `sudo tailscale up` once and approve it. Then apply the work agent-host tag to the node in the admin console.
   Tagged nodes have key expiry disabled. A switch can upgrade the formula and restart the daemon, so don't run
   `darwin-rebuild` over a Tailscale ssh session you can't lose.

8. **Work repos.** Clone into `~/projects/work`. Use `git@github.com:<org>/<repo>.git` URLs: git rewrites them to
   the `github.com-work` alias.

9. **Claude Code, work login.** Run `claude-work` inside `~/projects/work`, accept the trust prompt, then
   `/login` with the work account. The `claude-rc-work` launchd agent waits for that login and then starts Remote
   Control; the session shows on claude.ai under the work login.

10. **Codex (if used).** `codex-work login --device-auth`.

11. **Checks.**

    ```sh
    agents status          # claude-rc-work (and codex-rc-work) running
    pmset -g | grep -E '^ *(sleep|disksleep|autorestart|womp) '
    # expected: sleep 0, disksleep 0, autorestart 1, womp 1
    for s in getcomputersleep getrestartpowerfailure getwakeonnetworkaccess; do sudo systemsetup -$s; done
    sudo brew services list | grep tailscale   # started, user root
    ```

    nix-darwin applies the power settings with `systemsetup` on every switch. If `pmset -g` disagrees, set them by
    hand with `sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1` and report the mismatch.

12. **No personal files.** None of these may exist:

    ```sh
    ls -la ~/.config/personal ~/.ssh/id_ed25519 ~/projects/personal/.env ~/projects/personal/.op-connect \
      ~/projects/personal/.envrc ~/.config/memory ~/.local/share/second-brain 2>&1 | grep -v 'No such file'
    ```

    The output should be empty.

## FileVault and unattended reboots (owner decision)

The Remote Control agents are per-user launchd agents, so they run only inside a logged-in session. With
`autorestart 1` the Mac powers back on after an outage, but:

- **FileVault on** (the default for a new Mac): the disk stays locked at the pre-boot screen until someone logs
  in, so nothing runs (not even the Tailscale daemon) until a person unlocks it. macOS does not allow automatic
  login while FileVault is on. Planned reboots can use `sudo fdesetup authrestart`, which unlocks once.
- **FileVault off and automatic login on**: the host comes back by itself after an outage, logs in and starts
  Remote Control. The cost is an unencrypted disk at rest and an open session on a machine with work credentials.

This repo does not set either. Choose one and record it.
