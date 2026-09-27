#!/bin/bash
# scripts/tailnet-verify.sh — read-only evidence for add-netcup-tailnet.
#
# The runbook form of openspec/changes/archive/2026-09-27-add-netcup-tailnet/tasks.md groups 5-9.
# It reads only, and it is meant to be run TWICE: once after the deploy (which
# must leave the host running tailscaled but NOT enrolled) and once after the
# enrollment. The host's own BackendState decides which invariant set applies,
# so the script is honest about which phase it is looking at instead of
# reporting a wall of FAILs for the state it is not in.
#
# The reboot check is deliberate and separate (scripts/tailnet-reboot-check.sh)
# because it interrupts the host.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * `tailscaled-autoconnect` is Type=notify and EXITS 0 once the node is
#     Running. After success `systemctl is-active` says `inactive` — that is the
#     healthy answer, not a failure. Judge it by `Result=`, never by is-active.
#   * The node NAME comes from `--hostname` and the TAG comes from the auth key,
#     so neither is visible in the closure. `tailscale status --json` is the
#     only surface that reports them.
#   * The public path and the overlay path are the same sshd on the same host
#     key, so the overlay name needs its own known_hosts entry.
#   * The auth key file is only read by the autoconnect unit when the node is
#     NOT Running. Its absence after enrollment is therefore legal, though it
#     costs self-enrollment on a future re-image — reported as a NOTE, not a
#     FAIL.
#   * With the key ABSENT the unit is SKIPPED, not failed: tailnet.nix pins
#     `ConditionPathExists=$AUTHKEY_PATH` on it, because a failed unit makes
#     switch-to-configuration exit 4 and rolls the deploy back. So the
#     pre-enrollment evidence is `ConditionResult=no`, and the journal has
#     nothing to say about the missing key (the unit never ran).
set -u

KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
NODE=${NODE:-nc}
TAILNET_SUFFIX=${TAILNET_SUFFIX:-worm-hue.ts.net}
AUTHKEY_PATH=${AUTHKEY_PATH:-/var/lib/tailscale/authkey}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rc=0

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh()  { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }        # public path, root (what deploy uses)
osh()  { ssh "${SSHOPTS[@]}" hbohlen@"$PUBLIC" "$@"; }     # public path, operator
rshN() { ssh "${SSHOPTS[@]}" root@"$NODE.$TAILNET_SUFFIX" "$@"; }    # overlay path
oshN() { ssh "${SSHOPTS[@]}" hbohlen@"$NODE.$TAILNET_SUFFIX" "$@"; }

norm() { tr -s ' \t' ' ' ; }
check() { # check <label> <expected-substring> <actual>
  local exp act
  exp=$(printf '%s' "$2" | norm); act=$(printf '%s' "$3" | norm)
  if printf '%s' "$act" | grep -qF -- "$exp"; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n        expected: %s\n        actual:   %s\n' "$1" "$exp" "$(printf '%s' "$act" | tr '\n' '|' | cut -c1-200)"; rc=1; fi
}
note() { printf '  NOTE %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

[ -r "$KEY" ] || { printf 'FAIL: %s missing — materialize it (docs/install-netcup.md step 1; it needs an appended trailing newline)\n' "$KEY" >&2; exit 1; }

step "the deployed host runs tailscaled"
out=$(rsh 'systemctl is-active tailscaled; systemctl is-enabled tailscaled') || { echo "  FAIL cannot reach $PUBLIC as root"; exit 1; }
printf '%s\n' "$out" | sed 's/^/  /'
check "tailscaled active" "active" "$(printf '%s' "$out" | head -1)"
check "tailscaled enabled" "enabled" "$(printf '%s' "$out" | tail -1)"
out=$(rsh 'tailscale version | head -1')
printf '  host tailscale: %s\n' "$out"

step "the host's backend state decides which invariants are checked"
state=$(rsh 'tailscale status --json --peers=false 2>/dev/null' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
[ -n "$state" ] || state=UNKNOWN
printf '  BackendState: %s\n' "$state"

step "the autoconnect unit (judged by Result, never by is-active)"
out=$(rsh 'systemctl show -p Result --value tailscaled-autoconnect; systemctl show -p ExecMainStatus --value tailscaled-autoconnect')
printf '%s\n' "$out" | sed 's/^/  /'

step "the public access path still works (this change must not weaken it)"
out=$(osh 'hostname')
check "operator key login over the public address" "netcup" "$out"
out=$(rsh 'hostname')
check "root key login over the public address" "netcup" "$out"

if [ "$state" != "Running" ]; then

  printf '\n### PRE-ENROLLMENT (BackendState=%s) — the expected state straight after the deploy\n' "$state"
  step "the host is not enrolled, and the tailnet does not yet know it"
  out=$(rsh 'tailscale status' 2>&1 | head -3)
  printf '%s\n' "$out" | sed 's/^/  /'
  check "the host reports itself logged out" "Logged out" "$out"
  keyfile=$(rsh "stat -c '%a %U %G' $AUTHKEY_PATH 2>/dev/null || echo ABSENT")
  printf '  %s -> %s\n' "$AUTHKEY_PATH" "$keyfile"
  if [ "$keyfile" = "ABSENT" ]; then
    printf '  OK   the auth key is not on the host yet\n'
    # READ THIS BEFORE "FIXING" IT: with no key at $AUTHKEY_PATH the unit must be
    # SKIPPED, not failed. A FAILED new unit makes `switch-to-configuration switch`
    # exit 4 and devenv roll the whole transaction back (measured 2026-09-27:
    # `phase: "rolled-back"`, previousSystem restored) — so a failed unit here
    # would mean the deploy could never have been accepted, which is why
    # hosts/netcup/tailnet.nix pins ConditionPathExists on the unit. The evidence
    # is the condition's result, not a journal line about the missing file: a
    # skipped unit never runs, so it never logs anything.
    check "the autoconnect unit is skipped for want of a key" "no" \
      "$(rsh 'systemctl show -p ConditionResult --value tailscaled-autoconnect')"
    check "the autoconnect unit is not in a failed state" "inactive" \
      "$(rsh 'systemctl is-failed tailscaled-autoconnect 2>/dev/null || true')"
  fi
  python3 - "$NODE" <<'PY' || rc=1
import json,subprocess,sys
node=sys.argv[1]
d=json.loads(subprocess.run(["tailscale","status","--json"],capture_output=True,text=True).stdout)
peers=d.get("Peer",{}) or {}
hits=[p for p in peers.values() if p.get("HostName")==node]
print("  the tailnet knows %d node(s) named %s" % (len(hits), node))
sys.exit(1 if hits else 0)
PY
  printf '\nPRE-ENROLLMENT CHECKS %s\n' "$([ $rc -eq 0 ] && echo PASSED || echo FAILED)"
  printf 'Next, and this writes to the host: put the key at %s with mode 0600 root:root,\n' "$AUTHKEY_PATH"
  printf 'then `systemctl start tailscaled-autoconnect` — tasks.md 7.1-7.3.\n'
  exit "$rc"
fi

printf '\n### ENROLLED (BackendState=Running)\n'

step "the host is Running and holds a tailnet address"
out=$(rsh 'tailscale status --peers=false | head -3; echo "--- ipv4:"; tailscale ip -4')
printf '%s\n' "$out" | sed 's/^/  /'
check "the host reports a 100.x address" "100." "$out"
lip=$(rsh 'tailscale ip -4' | head -1)
check "the host's own name is $NODE" "$NODE" "$(rsh 'tailscale status --json --peers=false' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"])')"

step "$AUTHKEY_PATH after enrollment"
keyfile=$(rsh "stat -c '%a %U %G' $AUTHKEY_PATH 2>/dev/null || echo ABSENT")
printf '  %s -> %s\n' "$AUTHKEY_PATH" "$keyfile"
if [ "$keyfile" = "ABSENT" ]; then
  note "no key at rest (the unit does not need it while the node is Running), but a future re-image loses self-enrollment"
else
  check "the key is readable only by root" "600 root root" "$keyfile"
fi

step "the enrollment succeeded, in the tailnet's own view"
check "autoconnect reported success" "success" "$(rsh 'systemctl show -p Result --value tailscaled-autoconnect')"
if rsh 'journalctl -u tailscaled-autoconnect -b --no-pager' 2>/dev/null | grep -q 'sending auth key'; then
  printf '  OK   this boot used the key (expected on the enrolling boot; the reboot check proves it is not needed again)\n'
fi

step "the tailnet agrees: one node named $NODE, tagged, online"
ts_json=$(mktemp) || exit 1
trap 'rm -f "$ts_json"' EXIT
tailscale status --json > "$ts_json" 2>/dev/null || { echo "  FAIL tailscale status --json on the workstation"; exit 1; }
python3 - "$ts_json" "$NODE" "$TAILNET_SUFFIX" "$lip" <<'PY'
import json,sys
path,node,suffix,lip=sys.argv[1:5]
d=json.load(open(path)); peers=d.get("Peer",{}) or {}
hits=[p for p in peers.values() if p.get("HostName")==node or (p.get("DNSName") or "").startswith(node+".")]
print("  nodes named %s: %d" % (node, len(hits)))
rc=0
if len(hits)!=1: print("  FAIL expected exactly one node named %s" % node); rc=1
else:
    p=hits[0]
    for label,got,exp in [
        ("DNSName", p.get("DNSName"), node+"."+suffix+"."),
        ("Online", p.get("Online"), True),
        ("OS", p.get("OS"), "linux"),
    ]:
        ok = got==exp
        print("  %s %s = %r (expected %r)" % ("OK  " if ok else "FAIL", label, got, exp))
        if not ok: rc=1
    tags=p.get("Tags") or []
    ok = "tag:server" in tags
    print("  %s Tags = %r (expected to contain 'tag:server' — the ACL bucket every other node here is in)" % ("OK  " if ok else "FAIL", tags))
    if not ok: rc=1
    ips=p.get("TailscaleIPs") or []
    ok = lip in ips
    print("  %s the host's own ip %s appears in the peer record %r" % ("OK  " if ok else "FAIL", lip, ips))
    if not ok: rc=1
sys.exit(rc)
PY
[ $? -eq 0 ] || rc=1

step "the name resolves, and the overlay carries traffic"
out=$(timeout 15 tailscale ping "$NODE" 2>&1 | head -2)
printf '%s\n' "$out" | sed 's/^/  /'
check "tailscale ping answers" "pong" "$out"
out=$(tailscale ip -4 "$NODE" 2>&1)
check "MagicDNS name resolves to a tailnet address" "100." "$out"

step "login over the overlay, as both principals"
out=$(oshN 'hostname; tailscale ip -4' 2>&1)
printf '%s\n' "$out" | sed 's/^/  /'
check "operator key login over $NODE.$TAILNET_SUFFIX" "netcup" "$out"
out=$(rshN 'hostname' 2>&1)
check "root key login over $NODE.$TAILNET_SUFFIX" "netcup" "$out"

step "nothing else moved"
out=$(rsh 'systemctl is-system-running; systemctl --failed --no-legend | wc -l')
printf '%s\n' "$out" | sed 's/^/  /'
printf '  The firewall-facts assertion lives in scripts/tailnet-preflight.sh step 8,\n'
printf '  because evaluating deploy.facts needs the vault and this script does not.\n'

printf '\n'
if [ "$rc" -eq 0 ]; then echo "ALL TAILNET CHECKS PASSED"; else echo "SOME CHECKS FAILED (see FAIL lines above)"; fi
printf 'Reboot survival is a separate, deliberate interruption: scripts/tailnet-reboot-check.sh\n'
exit "$rc"
