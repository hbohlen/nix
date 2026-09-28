#!/usr/bin/env bash
# scripts/postinstall-verify.sh — post-install evidence for the netcup Machine.
#
# The runbook form of docs/install-netcup.md step 6. Reads only; the reboot
# check is deliberate and separate (it interrupts the host).
#
# KNOWN NixOS DETAILS THIS SCRIPT CODES IN (learned the hard way 2026-09-27):
#   * authorized keys live in /etc/ssh/authorized_keys.d/<user>, NOT
#     ~/.ssh/authorized_keys — the NixOS sshd module renders them itself, so a
#     script looking in $HOME reports "no such file" on a perfectly good host.
#   * findmnt takes ONE target per invocation; passing several silently yields
#     nothing.
#   * lsblk prints a btrfs device once and collapses the other subvolume
#     mountpoints, so /nix and /var are invisible there even when mounted.
set -u

KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
EXPECTED_FP='SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ'
TARGET=${TARGET:-152.53.92.126}
SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$KEY")
rc=0

norm() { tr -s ' \t' ' ' ; }
check() { # check <label> <expected-substring> <actual>
  local exp act
  exp=$(printf '%s' "$2" | norm); act=$(printf '%s' "$3" | norm)
  if printf '%s' "$act" | grep -qF -- "$exp"; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n        expected: %s\n        actual:   %s\n' "$1" "$exp" "$(printf '%s' "$act" | tr '\n' '|' | cut -c1-200)"; rc=1; fi
}
step() { printf '\n== %s ==\n' "$*"; }
rsh() { ssh "${SSHOPTS[@]}" root@"$TARGET" "$@"; }
osh() { ssh "${SSHOPTS[@]}" hbohlen@"$TARGET" "$@"; }   # the operator account, not root

step "root login with the vault identity"
out=$(rsh 'echo "$(hostname) $(id -un)"') || { echo "  FAIL root ssh"; exit 1; }
check "root ssh works" "netcup root" "$out"

step "it is NixOS, not the installer environment"
out=$(rsh 'nixos-version; echo "--- cmdline:"; cat /proc/cmdline')
printf '%s\n' "$out" | sed 's/^/  /'
check "nixos-version reports the release" "26.11" "$out"
if printf '%s' "$out" | grep -q 'nixos-installer'; then printf '  FAIL still running the installer\n'; rc=1; else printf '  OK   not the installer environment\n'; fi

step "operator account: key-only login, wheel, passwordless sudo"
out=$(osh 'id -un; id -nG; sudo -n true && echo SUDO_OK')
check "operator key login (not root)" "hbohlen" "$out"
check "operator is in wheel" "wheel" "$out"
check "passwordless sudo" "SUDO_OK" "$out"
out=$(rsh 'getent shadow hbohlen | cut -d: -f2 | cut -c1')
printf '  hbohlen shadow marker: %s\n' "$out"
check "operator has no usable password" "!" "$out"

step "password authentication is refused"
out=$(ssh -F /dev/null -o ConnectTimeout=10 -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no -o BatchMode=yes -o IdentitiesOnly=yes root@"$TARGET" true 2>&1)
printf '  %s\n' "$out"
check "server offers only publickey" "Permission denied (publickey)" "$out"

step "authorized keys, read from where NixOS actually puts them"
out=$(rsh 'for f in /etc/ssh/authorized_keys.d/root /etc/ssh/authorized_keys.d/hbohlen; do printf "%s: " "$f"; ssh-keygen -lf "$f" 2>&1 | awk "{print \$2}" | sort -u | tr "\n" " "; echo; done')
printf '%s\n' "$out" | sed 's/^/  /'
check "root trusts the vault identity" "$EXPECTED_FP" "$out"
count=$(rsh 'cat /etc/ssh/authorized_keys.d/root | grep -c .')
check "root trusts exactly one key" "1" "$count"

step "the disko layout is the mounted reality"
out=$(rsh 'for m in / /home /nix /var; do printf "%-6s " "$m"; findmnt -no SOURCE,FSTYPE,OPTIONS "$m"; done')
printf '%s\n' "$out" | sed 's/^/  /'
for sv in "subvol=/@" "subvol=/@home" "subvol=/@nix" "subvol=/@var" "compress=zstd" "noatime"; do
  check "mounted with $sv" "$sv" "$out"
done
out=$(rsh 'lsblk -P -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep vda')
printf '%s\n' "$out" | sed 's/^/  /'
check "ESP is 1G vfat at /boot" 'NAME="vda1" SIZE="1G" FSTYPE="vfat" MOUNTPOINT="/boot"' "$out"
check "root partition is btrfs and takes the disk" 'NAME="vda2"' "$out"

step "no swap"
out=$(rsh 'swapon --show')
if [ -z "$out" ]; then printf '  OK   swapon reports nothing\n'; else printf '  FAIL swap is active: %s\n' "$out"; rc=1; fi

step "the bootloader — and WHICH path it actually booted from"
out=$(rsh 'bootctl status')
printf '%s\n' "$out" | sed -n '/System:/,/Platform Lang/p; /Current Boot Loader/,/Current Entry/p' | sed 's/^/  /'
# `Product: systemd-boot` is the loader; `Current Entry:` names the generation.
# Measured 2026-09-27: this host boots from /boot/EFI/BOOT/BOOTX64.EFI — the
# UEFI FALLBACK path — not from an NVRAM entry, because the config sets
# canTouchEfiVariables = false (netcup's VPS NVRAM is unreliable). The fallback
# binary is therefore load-bearing, not a convenience.
check "systemd-boot is the bootloader" "Product: systemd-boot" "$out"
check "it booted a nixos generation entry" "Current Entry: nixos-" "$out"
out=$(rsh 'ls -l /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI /boot/loader/loader.conf 2>&1; printf "default entry: "; grep ^default /boot/loader/loader.conf')
printf '%s\n' "$out" | sed 's/^/  /'
check "fallback bootloader path exists" "BOOTX64.EFI" "$out"
check "loader.conf has a default entry" "nixos-" "$out"

step "the system is up, not degraded"
out=$(rsh 'systemctl is-system-running')
printf '  systemctl is-system-running: %s\n' "$out"
case "$out" in running|degraded) printf '  OK   settled\n';; *) printf '  FAIL not settled\n'; rc=1;; esac
failed=$(rsh 'systemctl --failed --no-legend | wc -l')
printf '  failed units: %s\n' "$failed"

step "the devenv recovery watchdog and its facts file are on the host"
out=$(rsh 'systemctl is-enabled devenv-machines-recover 2>&1; head -c 120 /etc/devenv/machine-facts.json 2>/dev/null; echo')
printf '%s\n' "$out" | sed 's/^/  /'
check "recovery watchdog enabled" "enabled" "$out"
check "the host reports itself as netcup" '"hostname":"netcup"' "$out"

printf '\n'
if [ "$rc" -eq 0 ]; then echo "ALL POST-INSTALL CHECKS PASSED"; else echo "SOME CHECKS FAILED (see FAIL lines above)"; fi
exit "$rc"
