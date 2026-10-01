# Linux Agent Host — Design

**Date:** 2026-09-30
**Status:** Approved (brainstorming), pending implementation plan

## Goal

Manage headless Ubuntu servers that host AI agent sessions from this flake,
without disturbing the existing macOS (nix-darwin) hosts.

The first host is `ai-agent-host` (x86_64). A second host will follow, and
both will run at the same time.

On each host:

- The OS stays Ubuntu. Nix manages it through two pieces:
  - **system-manager** (numtide) owns a small, declarative OS layer.
  - **standalone home-manager** owns the user environment.
- The user environment matches the Macs, minus anything that needs a GUI:
  - shell, tmux, starship, atuin, zoxide, direnv and mise;
  - git identities with commit signing;
  - ssh keys and `.env` files from 1Password;
  - the Claude Code customizations.
- Claude Code and Codex can each be used with **two accounts**, `personal` and
  `work`. An always-on Remote Control server runs for each tool and each
  account.

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Hosts | One x86_64 host now (`ai-agent-host`), a second later. One output per host, sharing modules. |
| 2 | OS management | Ubuntu + Nix. system-manager for the OS layer, standalone home-manager for the user. |
| 3 | Identities | Personal and work git/ssh identities. Work secrets use their own 1Password service-account token. |
| 4 | Session model | Remote Control, mostly unattended. Interactive tmux is still available. |
| 5 | Remote Control servers | Always on: one systemd user service per tool per account, started at boot via lingering. |
| 6 | Claude Code / Codex install | Their native installers, which update themselves. Nix does not install them; it only wraps them. |
| 7 | sshd / Tailscale | Keep Ubuntu's `sshd` service and the apt Tailscale package. system-manager only adds an sshd config drop-in. |
| 8 | Accounts | `personal` → `~/projects/personal`, `work` → `~/projects/work`, for both tools. |
| 9 | `op` CLI | Keep the apt `1password-cli` beta for interactive use. op-secrets keeps using its own Nix-pinned `op`. |

## Current state of `ai-agent-host` (inventoried 2026-09-30)

- **System:** Ubuntu 26.04.1 LTS, x86_64, 16 CPU cores, 60 GiB RAM, 1.8 TB free.
- **User and access:**
  - user `nwilliams-lucas` (uid 1000), groups `sudo` and `adm`;
  - passwordless sudo; login shell `/bin/zsh`.
- **sshd:** already hardened by `/etc/ssh/sshd_config.d/10-hardening.conf`:
  - `PasswordAuthentication no`, `KbdInteractiveAuthentication no`;
  - `PermitRootLogin no`, `PubkeyAuthentication yes`.
- **Tailscale** 1.102.4 from apt. `tailscaled` is running, but `tailscale status`
  reports `Logged out.`, so the node needs checking and `tailscale up`.
- **Lingering** is off (`Linger=no`).
- **Nix:** not installed (`/nix` does not exist).
- **Tools and where they came from:**

  | Tool | Location | Source |
  |---|---|---|
  | Claude Code 2.1.285 | `~/.local/bin` | native installer |
  | Codex 0.159.2 | `~/.local/bin` | native installer |
  | mise | `~/.local/bin` | native installer |
  | zoxide | `~/.local/bin` | native installer |
  | atuin | `~/.atuin/bin` | native installer |
  | starship | `/usr/local/bin` | native installer |
  | direnv | `/usr/bin` | apt |
  | tmux, zsh, git | system | apt |
  | `op` 2.40.0-beta.02 | `/usr/bin` | apt |
  | rustup / cargo | `~/.cargo` | rustup |

- **atuin history** is in `~/.local/share/atuin`. It must be kept.
- **Claude Code and Codex are not logged in.** `~/.claude` holds only
  scaffolding, and `~/.claude.json` has no `oauthAccount`.
- **Hand-written dotfiles** home-manager will take over:
  - `~/.zshrc`, `~/.zshenv` and `~/.bashrc`, each with atuin, starship, zoxide,
    direnv or mise hooks;
  - `~/.ssh/config`.
- **ssh keys:** `~/.ssh/id_ed25519` and `~/.ssh/gitlab-work-gl` are already on
  disk.

## Architecture

### Flake layout

- **New input:** `system-manager` (`github:numtide/system-manager`, pinned to a
  release, with `nixpkgs.follows = "nixpkgs-stable"`).
- **Host discovery:** hosts are discovered from `hosts/linux/*.nix`, and the
  filename is the hostname, like `mkHosts` today. Each host file is an attrset
  `{ home = <hm module>; system = <system-manager module>; }`.
- **New outputs**, generated per host:
  - `homeConfigurations."nwilliams-lucas@<host>"` via
    `hm.lib.homeManagerConfiguration`. It uses `nixpkgs-stable` for x86_64-linux
    with `allowUnfree` and the shared overlays, and passes `extraSpecialArgs`
    `user`, `version`, `theme`, `inputs` and `PROJECT_ROOT`.
  - `systemConfigs.<host>` via `system-manager.lib.makeSystemConfig`.
- **Unchanged:** the existing `darwinConfigurations` and `nixosConfigurations`
  outputs.

### `home/standalone.nix`: the standalone entry module

When home-manager runs inside nix-darwin or NixOS, the system layer provides
several things. This module provides them itself:

- **Shell options:** the `d.shell` option (`aliases`, `variables`, `sources`)
  and how it applies: `home.shellAliases` and `home.sessionVariables`. Today
  this comes from `modules/shell.nix`. Move the shared definition into a
  module both paths import, so the system and standalone paths can't drift.
- **CLI modules:** imports `home/cli`, which `modules/profiles/base.nix` injects
  on the Macs through `d.hm`.
- **Non-NixOS mode:** `targets.genericLinux.enable = true`.
- **Shell programs** that live in the system shell modules on the Macs:
  - `programs.zsh.enable` with autosuggestions;
  - `programs.direnv.enable` with `nix-direnv`;
  - mise zsh integration turned on for standalone.
- **nix-index:** the `inputs.nix-index.homeModules.nix-index` import.
- **Secrets:** the `inputs.op-secrets.hmModules.default` import.
- **`switch` alias:** runs `home-manager switch` and `system-manager switch`
  for this host.

### Portability fixes in existing `home/` modules

The Macs must evaluate to the same system as before. Any difference in the
darwin build has to be explained.

- **`home/cli/git/default.nix`:** `settings.gpg.ssh.program` uses
  `/Applications/1Password.app/.../op-ssh-sign` on macOS only. Elsewhere it uses
  `${pkgs.openssh}/bin/ssh-keygen`, and the default signing key is the on-disk
  personal key.
- **`home/ssh_config.nix`:**
  - The `ProxyCommand` entries use `${pkgs.cloudflared}/bin/cloudflared` off
    macOS, and keep `/opt/homebrew/bin/cloudflared` on macOS.
  - The `onePassword` `IdentityAgent` block is macOS-only.
- **`home/apps/1password.nix`:**
  - Adds `d.apps.onepassword.gui` (default `true`). The agent socket, the
    global `IdentityAgent`, `SSH_AUTH_SOCK`, GUI signing and the
    `_1password-gui` autostart all depend on it.
  - op-secrets stays active whenever `d.apps.onepassword.enable` is on.
  - The `work-env` secret gets a `serviceAccountTokenCommand` that reads
    `~/.config/work/1penv` on agent hosts, so it no longer depends on an
    interactive desktop session.
- **`home/default.nix`:**
  - The `nix-darwin-reinit` script is installed on macOS only.
  - `xsession.numlock.enable = false`.
  - Keeps `programs.mise.enableZshIntegration = false` on the Macs; standalone
    turns it on.
- **Everything else** is left as it is. `iterm2` is already macOS-only, and the
  launchd jobs in `rust.nix` are already gated.

### System layer: `system/linux/` (system-manager)

- **Nix configuration:**
  - `nix.settings`: `experimental-features = nix-command flakes`,
    `download-buffer-size = 134217728`, `warn-dirty = false`,
    `trusted-users = root nwilliams-lucas`.
  - `!include /etc/nix/github-token.conf`.
  - **Risk:** the Nix installer also writes `/etc/nix/nix.conf`. If
    system-manager can't take that file over cleanly, write
    `/etc/nix/nix.custom.conf`, which the installer's config includes, instead.
- **Garbage collection:** a weekly systemd timer (Sundays) runs
  `nix-collect-garbage --delete-older-than 30d` and `nix store optimise`, to
  match the Macs.
- **Lingering:** a tmpfiles rule creates `/var/lib/systemd/linger/nwilliams-lucas`.
- **sshd drop-in:** `/etc/ssh/sshd_config.d/05-nix-hardening.conf` with the same
  four settings as `10-hardening.conf`. `05-` beats `50-cloud-init.conf`, since
  sshd uses the first value it reads. Validate with `sshd -t` before reloading.
- **Deliberately not managed:** the sshd service, Tailscale, apt, zsh, users.

### Agent tooling: `home/agent-host/`

This is gated by `d.agentHost.enable`, default `false`, so the Macs aren't
affected.

- **Accounts:** `d.agentHost.accounts.<acct>.root`, set to `personal` →
  `~/projects/personal` and `work` → `~/projects/work`.
- **Per-account config directories:**
  - Claude Code: `CLAUDE_CONFIG_DIR=~/.claude-<acct>`.
  - Codex: `CODEX_HOME=~/.codex-<acct>`.
  - `home/cli/claude`'s `commands/brain.md` is linked into every Claude
    directory, and the `gitnexus setup -c claude` activation runs once per
    directory with `CLAUDE_CONFIG_DIR` set.
- **Choosing the account:**
  - **By directory:** on agent hosts, the direnv hooks for
    `~/projects/personal` and `~/projects/work` (in `home/default.nix`) also
    export that tree's `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
  - **Everywhere else:** `home.sessionVariables` defaults to the `personal`
    account.
  - **Explicit commands:** `claude-<acct>` and `codex-<acct>` set the variables
    and exec `~/.local/bin/claude` or `~/.local/bin/codex`.
- **Services:** one systemd user service per tool per account,
  `claude-rc-<acct>` and `codex-rc-<acct>`, with `WantedBy=default.target`:
  - **`ExecStart`:**
    - Claude: `%h/.local/bin/claude remote-control --name <host>-<acct>`.
    - Codex: `%h/.local/bin/codex remote-control`, the foreground form, so
      systemd supervises the process.
  - **`WorkingDirectory`:** the account's root.
  - **`Environment`:**
    - `CLAUDE_CONFIG_DIR` or `CODEX_HOME`;
    - a full `PATH`: `%h/.local/bin`, mise shims, `%h/.nix-profile/bin`,
      `/nix/var/nix/profiles/default/bin`, `%h/.cargo/bin`, then system paths.
  - **`EnvironmentFile=-%h/projects/<acct>/.env`** passes the op-provisioned
    tokens through. `GH_TOKEN` is mirrored from `GITHUB_PERSONAL_ACCESS_TOKEN`
    in the wrapper.
  - **`ExecCondition`:** the account's credentials file must exist
    (`.credentials.json` for Claude, `auth.json` for Codex). Before login the
    unit is skipped instead of looping.
  - **`Restart=always`, `RestartSec=10`, `StandardInput=null`.**
  - **No scheduled restarts**, because they would kill live sessions.
    Native-installer updates take effect on the next restart.
- **`agents` helper:** `agents status | restart [unit] | logs <unit>` across the
  four units.
- **Things to verify during implementation:**
  - whether `~/.claude.json` follows `CLAUDE_CONFIG_DIR` (it only affects
    onboarding state, not credentials);
  - whether the `.env` templates parse as systemd `EnvironmentFile` (plain
    `KEY=VALUE`, quoting).

### Host file: `hosts/linux/ai-agent-host.nix`

- **`home`:** `d.agentHost.enable = true`, `d.apps.onepassword.gui = false`,
  and the account roots.
- **`system`:** `nixpkgs.hostPlatform = "x86_64-linux"` and the host's
  system-manager options.

## Bootstrap: `scripts/bootstrap-agent-host.sh`

The script is idempotent and supports `--dry-run`. Each step checks before it
acts.

1. **Install Nix** if `/nix` is missing, using the installer system-manager is
   tested against.
2. **Write the 1Password tokens.** Prompt, without echo, for the personal and
   work service-account tokens and write them to `~/.config/personal/1penv` and
   `~/.config/work/1penv`, directories 0700 and files 0600. Skip any file that
   already exists.
3. **Remove duplicate native tools:**
   - `~/.atuin/bin` (keep `~/.local/share/atuin`; move `~/.config/atuin` aside);
   - `/usr/local/bin/starship`;
   - `~/.local/bin/zoxide`;
   - `~/.local/bin/mise`;
   - the apt `direnv`.

   **Keep:** Claude Code, Codex, rustup and the apt `op`.
4. **Clone the repo** to `~/projects/personal/nix-darwin-hm` if it's missing.
5. **First switches:**
   - `sudo system-manager switch --flake .#<host>`;
   - `home-manager switch -b backup --flake .#nwilliams-lucas@<host>`. This
     moves the hand-written rc files and `~/.ssh/config` to `*.backup`.
6. **GitHub token for private inputs:** `just materialize-nix-github-token`.
   Fix the recipe to use `root:$(id -gn root)` instead of the hardcoded
   `root:wheel`.
7. **Print the manual follow-ups:**
   - For each account: run `claude-<acct>` in its root (trust prompt and
     `/login`), then `codex-<acct> login --device-auth`.
   - `agents restart`.
   - `sudo tailscale up` if the node is logged out.

## Testing

**Build checks, on this Mac:**

- `nix fmt` is clean, and `nix flake check` passes.
- `nix build` of
  `homeConfigurations."nwilliams-lucas@ai-agent-host".activationPackage` and
  `systemConfigs.ai-agent-host`, built through the linux-builder.
- `nix build` of `darwinConfigurations.NWL-MMINI.system`, with the output path
  compared against `main`. Any difference has to be explained.

**Evaluation assertions:**

- The agent-host generation has no `_1password-gui`, no `/Applications/` or
  `/opt/homebrew/` strings, and no launchd configuration.
- The four user units exist with the expected `WorkingDirectory`,
  `Environment` and `ExecCondition`.

**On-host checks after bootstrap:**

- `git config user.email` inside each tree shows the matching identity.
- `ssh -T git@github.com` authenticates as `nwlucas`, and
  `ssh -T git@github.com-work` as `nwilliams-lucas`.
- A signed commit in each tree verifies.
- `systemctl --user list-units 'claude-rc-*' 'codex-rc-*'` shows the units
  skipped on their condition before login, and running after login.
- `loginctl show-user nwilliams-lucas -p Linger` returns `Linger=yes`.

**After logins:**

- Each Remote Control server appears under the right account in claude.ai or
  ChatGPT.
- The servers come back after a reboot.

## Rollback

- **home-manager:** activate a previous generation (`home-manager generations`).
  The `*.backup` files restore the hand-written dotfiles.
- **system-manager:** `system-manager deactivate`.
- The sshd service and Tailscale are never changed, so ssh access isn't at
  risk.

## Delivery

The work ships as four stacked PRs, each armed for auto-merge. Each PR deletes
its own branch and worktree after merging.

0. `chore/retire-codebase-brain-image`: deletes only
   `.github/workflows/codebase-brain-image.yml`. It doesn't depend on the other
   PRs. The `scripts/codebase-brain/` app,
   `modules/repomix/repomix.config.json` and the olympus-gitops deployment all
   stay; the deployment keeps the last published image.
1. `fix/linux-home-portability`: the portability fixes and the 1Password
   GUI/secrets split. The darwin build is unchanged.
2. `feat/standalone-home-manager`: `home/standalone.nix`, `hosts/linux/`
   discovery and the `homeConfigurations` output.
3. `feat/system-manager-agent-host`: the system-manager input, `system/linux/`,
   the bootstrap script and the `just` recipe fix.
4. `feat/agent-host-tooling`: `home/agent-host/`, with accounts, wrappers,
   services and `agents`.

**Docs to update:**

- `README.md`;
- `AGENTS.md` / `CLAUDE.md`: add `ai-agent-host` to "Current hosts" and an
  "Agent hosts" section covering bootstrap, accounts, logins and services;
- `ARCHITECTURE.md`: the new outputs and directories.

## Out of scope

- NixOS for these hosts.
- Managing Tailscale or sshd as services.
- Installing Claude Code or Codex through Nix.
- Scheduled agent jobs. The services layer makes them easy to add later.
- A Remote Control equivalent for tools other than Claude Code and Codex.
