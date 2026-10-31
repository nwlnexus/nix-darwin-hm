#!/usr/bin/env bash
# Dry walk of install.sh's macOS path with stubbed uname/curl/sudo/scutil/brew in temp dirs.
#   bash tests/install-sh.sh            (`just test-install-sh`)
# shellcheck disable=SC2015  # `A && ok || bad` is intentional: ok never fails
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# scenario <name>: fresh sandbox with stubs; sets $sb, $log
scenario() {
  sb="$tmp/$1"
  log="$sb/log"
  mkdir -p "$sb/bin" "$sb/nix" "$sb/launchd" "$sb/home"
  : >"$log"
  # copy of the repo files install.sh reads
  mkdir -p "$sb/repo/hosts/darwinM"
  cp "$repo/install.sh" "$repo/flake.nix" "$sb/repo/"
  touch "$sb/repo/hosts/darwinM/testhost.nix"
  cat >"$sb/bin/uname" <<'S'
#!/bin/sh
echo Darwin
S
  cat >"$sb/bin/brew" <<'S'
#!/bin/sh
exit 0
S
  cat >"$sb/bin/scutil" <<'S'
#!/bin/sh
echo "${STUB_HOST:-testhost}"
S
  # curl emits a script that "installs" nix into the sandbox
  cat >"$sb/bin/curl" <<'S'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
cat <<'INNER'
#!/bin/sh
echo "installer $*" >>"$STUB_LOG"
mkdir -p "$NIX_ROOT/var/nix/profiles/default/bin" "$NIX_ROOT/var/nix/profiles/default/etc/profile.d"
printf '#!/bin/sh\nexit 0\n' >"$NIX_ROOT/var/nix/profiles/default/bin/nix"
chmod +x "$NIX_ROOT/var/nix/profiles/default/bin/nix"
: >"$NIX_ROOT/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
INNER
S
  cat >"$sb/bin/sudo" <<'S'
#!/bin/sh
echo "sudo $*" >>"$STUB_LOG"
[ -z "${STUB_SUDO_FAIL:-}" ]
S
  chmod +x "$sb"/bin/*
}

run() { # runs install.sh in the sandbox; output in $sb/out, status in $rc
  HOME="$sb/home" PATH="$sb/bin:$PATH" NIX_ROOT="$sb/nix" LAUNCHD_DIR="$sb/launchd" STUB_LOG="$log" \
    bash "$sb/repo/install.sh" >"$sb/out" 2>&1
  rc=$?
}

# 1. fresh Mac: upstream flag, sudo switch with the release from flake.nix, flakes conf
scenario fresh
run
[ $rc -eq 0 ] && ok "fresh: exits 0" || bad "fresh: exits 0 (rc=$rc)"
grep -q '^installer install --prefer-upstream-nix' "$log" && ok "fresh: installer gets --prefer-upstream-nix" || bad "fresh: --prefer-upstream-nix"
grep -q "^sudo $sb/nix/var/nix/profiles/default/bin/nix run nix-darwin/nix-darwin-[0-9.]*#darwin-rebuild -- switch --flake .#testhost" "$log" && ok "fresh: sudo darwin-rebuild switch" || bad "fresh: sudo switch ($(cat "$log"))"
grep -q 'nix-command flakes' "$sb/home/.config/nix/nix.conf" && ok "fresh: nix.conf written" || bad "fresh: nix.conf"

# 2. nix already present: no installer
scenario present
mkdir -p "$sb/nix/var/nix/profiles/default/bin" "$sb/nix/var/nix/profiles/default/etc/profile.d"
printf '#!/bin/sh\n' >"$sb/nix/var/nix/profiles/default/bin/nix"
chmod +x "$sb/nix/var/nix/profiles/default/bin/nix"
: >"$sb/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
run
{ [ $rc -eq 0 ] && ! grep -q '^curl' "$log"; } && ok "present: skips install" || bad "present: skips install"

# 3. Determinate receipt: refuse, no install, no switch
scenario det-receipt
echo '{"planner":{"planner":"macos"},"determinate_nix": true}' >"$sb/nix/receipt.json"
run
{ [ $rc -ne 0 ] && grep -q 'nix-installer uninstall' "$sb/out" && [ ! -s "$log" ]; } && ok "determinate receipt: stops with uninstall hint" || bad "determinate receipt"

# 4. Determinate LaunchDaemon: refuse
scenario det-launchd
touch "$sb/launchd/systems.determinate.nix-daemon.plist"
run
{ [ $rc -ne 0 ] && grep -q 'nix-installer uninstall' "$sb/out" && [ ! -s "$log" ]; } && ok "determinate launchd: stops" || bad "determinate launchd"

# 4b. Upstream Nix installed by the Determinate installer (--prefer-upstream-nix): its receipt says
# determinate_nix false and only the installer's nix-hook daemon exists. Not Determinate: proceed.
scenario upstream-by-detsys
mkdir -p "$sb/nix/var/nix/profiles/default/bin" "$sb/nix/var/nix/profiles/default/etc/profile.d"
printf '#!/bin/sh\n' >"$sb/nix/var/nix/profiles/default/bin/nix"
chmod +x "$sb/nix/var/nix/profiles/default/bin/nix"
: >"$sb/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
echo '{"planner":{"planner":"macos"},"determinate_nix": false}' >"$sb/nix/receipt.json"
touch "$sb/launchd/systems.determinate.nix-installer.nix-hook.plist"
run
{ [ $rc -eq 0 ] && ! grep -q 'nix-installer uninstall' "$sb/out"; } && ok "upstream via the DetSys installer: proceeds" || bad "upstream via the DetSys installer"

# 5. hostname mismatch: scutil hint, no switch
scenario badhost
STUB_HOST=nope run
{ [ $rc -ne 0 ] && grep -q 'scutil --set LocalHostName' "$sb/out" && ! grep -q '^sudo' "$log"; } && ok "bad hostname: hint, no switch" || bad "bad hostname"

# 6. failing switch: nonzero, no success banner
scenario switchfail
STUB_SUDO_FAIL=1 run
{ [ $rc -ne 0 ] && ! grep -q 'Setup complete' "$sb/out"; } && ok "switch failure: exits nonzero, no success" || bad "switch failure"

# 7. Linux: refuses
scenario linux
printf '#!/bin/sh\necho Linux\n' >"$sb/bin/uname"
run
{ [ $rc -ne 0 ] && grep -q bootstrap-agent-host "$sb/out"; } && ok "linux: points to bootstrap-agent-host.sh" || bad "linux"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
