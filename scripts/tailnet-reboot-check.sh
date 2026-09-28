#!/usr/bin/env bash
# scripts/tailnet-reboot-check.sh — the host must rejoin the tailnet by itself.
#
# This is the check that decides whether add-netcup-tailnet actually bought what
# it claims. `tailscaled-autoconnect` sends the auth key only while the node is
# NOT Running, and tailscaled persists its node key in /var/lib/tailscale — so
# after a reboot the node must come back Running WITHOUT the key being read
# again. If this ever needs the key on every boot, the auth key is load-bearing
# at runtime rather than at enrollment, and the whole install-time delivery
# argument collapses.
#
# The reboot is issued over the PUBLIC path on purpose: a reboot issued over the
# overlay would be testing the one thing it is meant to verify.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * `tailscaled-autoconnect` is Type=notify and exits 0 once Running, so
#     `systemctl is-active` reports `inactive` on a perfectly healthy host.
#     Success is `Result=success`; re-authentication is the literal string
#     "sending auth key" in the unit's this-boot journal.
#   * The overlay name and the public address are the same sshd on the same
#     host key, so the overlay name needs its own known_hosts entry.
#   * The recovery path if this fails is the netcup console — NOT SSH. Keep the
#     portal credentials (1Password dev vault, NETCUP_CONSOLE) to hand.
#   * THE HOST HAS NO python3 — it is a minimal NixOS. Parse its JSON on THIS side
#     of the ssh (tailnet-verify.sh:70 does it that way) or with grep; never with
#     a `python3 -c` executed by the remote shell. Measured 2026-09-27: that form
#     reported BackendState as unreadable on a host that was demonstrably Running.
#   * `timeout 15 rsh …` cannot work: no external command can call a shell
#     function. See the comment on rshT/rshNT below.
set -u

KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
NODE=${NODE:-nc}
TAILNET_SUFFIX=${TAILNET_SUFFIX:-worm-hue.ts.net}
SSHOPTS=(-F /dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh()  { ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$PUBLIC" "$@"; }
rshN() { ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$NODE.$TAILNET_SUFFIX" "$@"; }

# WHY THESE TWO EXIST. `timeout 15 rsh …` DOES NOT RUN rsh: `timeout` is an
# external binary and cannot see a shell FUNCTION, so it exits 127 with
# `timeout: failed to run command 'rsh': No such file or directory`. With stderr
# sent to /dev/null the wait loop below reads that as "the host is not back yet",
# so the public path could never be detected as back and the check reported a
# false negative on a host that was down for ten seconds. Measured 2026-09-27:
# the previous boot ended 17:30:18 UTC, this one began 17:30:28, sshd was active
# at 17:30:32 — and the check still failed after 410 s, every probe having failed
# in ~0 s with rc=127. So the timeout belongs INSIDE a command that is a real
# executable, i.e. ssh, and the loop checks rc so a broken wrapper can never look
# like an unreachable host again.
rshT()  { timeout 15 ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$PUBLIC" "$@"; }
rshNT() { timeout 15 ssh "${SSHOPTS[@]}" -o BatchMode=yes root@"$NODE.$TAILNET_SUFFIX" "$@"; }

rc=0
check() { local exp act; exp=$(printf '%s' "$2" | tr -s ' \t' ' '); act=$(printf '%s' "$3" | tr -s ' \t' ' ')
  if printf '%s' "$act" | grep -qF -- "$exp"; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n        expected: %s\n        actual:   %s\n' "$1" "$exp" "$(printf '%s' "$act" | tr '\n' '|' | cut -c1-200)"; rc=1; fi; }

before_boot=$(rsh 'cat /proc/sys/kernel/random/boot_id') || { printf 'FAIL: no root SSH over the public address\n' >&2; exit 1; }
before_ip=$(tailscale ip -4 "$NODE" 2>/dev/null) || before_ip=""
before_seen=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((p.get("Online") for p in (d.get("Peer") or {}).values() if p.get("HostName")==sys.argv[1]), "unknown"))' "$NODE" 2>/dev/null || echo unknown)
printf 'before: boot_id=%s\n' "$before_boot"
printf 'before: %s.tailnet ip=%s online=%s\n' "$NODE" "${before_ip:-<unresolved>}" "$before_seen"

printf '\n>> rebooting %s over the PUBLIC path\n' "$PUBLIC"
rsh 'systemctl reboot' >/dev/null 2>&1 || true
sleep 5

started=$(date +%s)
pub_at=""; ovl_at=""
for i in $(seq 1 40); do
  if [ -z "$pub_at" ]; then
    out=$(rshT 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null); probe_rc=$?
    # rc=127 means the probe itself could not be executed. That is a defect in
    # this script, never an unreachable host, and silently treating it as "not
    # back yet" is exactly how this check reported a false negative before.
    if [ "$probe_rc" -eq 127 ]; then
      printf '\nFAIL: the wait probe could not run at all (rc=127). This is a defect in this script, not a host problem — the host was never contacted.\n' >&2
      exit 1
    fi
    if [ "$probe_rc" -eq 0 ] && [ -n "$out" ]; then
      pub_at=$(( $(date +%s) - started ))
      printf '\n>> public path back after %ss (attempt %s)\n' "$pub_at" "$i"
      after_boot=$out
      continue
    fi
  elif [ -z "$ovl_at" ]; then
    out=$(rshNT 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null); probe_rc=$?
    if [ "$probe_rc" -eq 127 ]; then
      printf '\nFAIL: the overlay wait probe could not run at all (rc=127). This is a defect in this script, not a host problem.\n' >&2
      exit 1
    fi
    if [ "$probe_rc" -eq 0 ] && [ -n "$out" ]; then
      ovl_at=$(( $(date +%s) - started ))
      printf '>> OVERLAY path back after %ss\n' "$ovl_at"
      break
    fi
  fi
  sleep 10
done

if [ -z "$pub_at" ]; then
  printf '\nFAIL: no SSH over the public address within ~7 minutes. Recovery: netcup console (1Password dev vault, NETCUP_CONSOLE).\n' >&2
  exit 1
fi
if [ -z "$ovl_at" ]; then
  printf '\nFAIL: the host came back on the PUBLIC path but never on the overlay.\n' >&2
  printf 'The public path is still open, so diagnose with scripts/tailnet-verify.sh before touching the console.\n' >&2
  printf 'Likely causes: tailscaled did not start, the node key was lost from /var/lib/tailscale, or the auth key was needed again.\n' >&2
  exit 1
fi

printf '\nafter:  boot_id=%s\n' "$after_boot"
if [ "$after_boot" = "$before_boot" ]; then printf '  FAIL same boot_id — it did not actually reboot\n'; rc=1
else printf '  OK   this is a NEW boot\n'; fi

printf '\n== the node came back on its own\n'
out=$(rshN 'tailscale status --peers=false | head -2')
printf '%s\n' "$out" | sed 's/^/  /'
# NO python3 ON THE HOST. This host is a minimal NixOS with no python3, and
# running `tailscale status --json | python3 -c …` ON it fails with
# `bash: line 1: python3: command not found` — which the check reported as
# "BackendState is Running" failing, on a host that was demonstrably Running
# (measured 2026-09-27). The other scripts pipe the host's JSON to the
# WORKSTATION's python3 (tailnet-verify.sh:70); here grep is enough and needs
# nothing on the host but coreutils.
backend=$(rshN 'tailscale status --json --peers=false' | grep -oE '"BackendState": *"[^"]*"')
printf '  --- backend: %s\n' "${backend:-<unreadable>}"
check "BackendState is Running after the reboot" "Running" "$backend"

printf '\n== the auth key was NOT needed again\n'
out=$(rshN 'systemctl show -p Result --value tailscaled-autoconnect')
printf '  Result=%s\n' "$out"
check "the autoconnect unit succeeded" "success" "$out"
log=$(rshN 'journalctl -u tailscaled-autoconnect -b --no-pager 2>/dev/null')
if printf '%s' "$log" | grep -q 'sending auth key'; then
  printf '  FAIL this boot re-sent the auth key — the node key did not survive, so the key IS load-bearing at runtime\n'; rc=1
else
  printf '  OK   no "sending auth key" in this boot'\''s journal\n'
fi

printf '\n== the node address did not move\n'
after_ip=$(tailscale ip -4 "$NODE" 2>/dev/null) || after_ip=""
printf '  before=%s  after=%s\n' "${before_ip:-<none>}" "${after_ip:-<none>}"
if [ -z "$before_ip" ]; then
  printf '  NOTE no address was recorded before the reboot, so stability cannot be judged\n'
elif [ -z "$after_ip" ]; then
  printf '  FAIL the node has no tailnet address after the reboot\n'; rc=1
else
  check "the tailnet address is stable" "$before_ip" "$after_ip"
fi

printf '\n== both access paths answer\n'
check "operator over the overlay" "netcup" "$(ssh "${SSHOPTS[@]}" -o BatchMode=yes hbohlen@"$NODE.$TAILNET_SUFFIX" 'hostname' 2>&1)"
check "operator over the public path" "netcup" "$(ssh "${SSHOPTS[@]}" -o BatchMode=yes hbohlen@"$PUBLIC" 'hostname' 2>&1)"

printf '\n  public path back at %ss, overlay at %ss\n' "$pub_at" "$ovl_at"
printf '\n'
if [ "$rc" -eq 0 ]; then echo "UNATTENDED TAILNET REJOIN CHECK PASSED"; else echo "SOME CHECKS FAILED (see FAIL lines above)"; fi
exit "$rc"
