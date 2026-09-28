#!/usr/bin/env bash
# scripts/reboot-check.sh — task 8.6: the host must come back on its own.
#
# An unattended UEFI boot is the point of the whole disk layout
# (`canTouchEfiVariables = false` + the EFI/BOOT/BOOTX64.EFI fallback), so it
# is checked explicitly rather than assumed from "it booted during install".
#
# The host key is recorded before and after: a NixOS host keeps its ssh host
# keys in /etc/ssh, so they MUST survive the reboot. A changed fingerprint here
# would mean the boot re-ran first-boot key generation and deserves a look.
set -u

KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
TARGET=${TARGET:-152.53.92.126}
SSHOPTS=(-F /dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$TARGET" "$@"; }

before_boot=$(rsh 'cat /proc/sys/kernel/random/boot_id')
before_hostkey=$(ssh-keygen -F "$TARGET" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk '{print $3}' | cut -c1-40)
printf 'before: boot_id=%s\n' "$before_boot"
printf 'before: host key entry=%s\n' "${before_hostkey:-<none recorded>}"

printf '\n>> rebooting %s now\n' "$TARGET"
rsh 'systemctl reboot' >/dev/null 2>&1 || true
sleep 5

started=$(date +%s)
for i in $(seq 1 40); do
  out=$(timeout 15 ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$TARGET" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
  if [ -n "$out" ]; then
    elapsed=$(( $(date +%s) - started ))
    printf '\n>> back after %ss (attempt %s)\n' "$elapsed" "$i"
    printf 'after:  boot_id=%s\n' "$out"
    if [ "$out" != "$before_boot" ]; then printf '  OK   this is a NEW boot\n'; else printf '  FAIL same boot_id — it did not actually reboot\n'; exit 1; fi
    hostkey_after=$(ssh-keygen -F "$TARGET" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk '{print $3}' | cut -c1-40)
    printf 'after:  host key entry=%s\n' "${hostkey_after:-<none>}"
    if [ "$hostkey_after" = "$before_hostkey" ]; then printf '  OK   host key survived the reboot\n'; else printf '  NOTE host key changed across the reboot — investigate (first-boot keygen re-ran?)\n'; fi
    rsh 'nixos-version; systemctl is-system-running; bootctl status | grep -E "Current Entry|Loader:"' | sed 's/^/  /'
    printf '\nUNATTENDED REBOOT CHECK PASSED\n'
    exit 0
  fi
  sleep 10
done

printf '\nFAIL: no SSH answer within ~7 minutes after reboot. Recovery: netcup console (1Password dev vault, NETCUP_CONSOLE).\n' >&2
exit 1
