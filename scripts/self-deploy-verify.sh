#!/bin/bash
# scripts/self-deploy-verify.sh — read-only evidence that the host can rebuild
# itself, as it now stands.
#
# The runbook form of openspec/changes/add-netcup-self-deploy/tasks.md group 5
# (the TL;DR and the build half) and group 6, checked from the workstation over
# the PUBLIC path. It writes nothing, deploys nothing, and builds nothing: it
# reads the host's checkout, its nix configuration, its loopback identity, its
# credential file and its recorded deploy state.
#
# THE HOST-TOUCHING SCRIPT, so per netcup-operations it is run in a pane and
# watched:
#   ./scripts/bb-pane-run.sh --title "host preconditions" -- ./scripts/self-deploy-verify.sh
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * The store is read-write on the live host only because
#     nix-store-remount-rw.service ran at boot; a fresh install boots with it
#     read-only and can RECEIVE copies but not BUILD. That is risk R11.
#   * `NIX_SSHOPTS` must name the declared identity for every path that reaches a
#     store over ssh — `nix copy --to ssh://…`, `nix store info --store ssh://…`.
#     Without it ssh offers the invoking user's default key and the target
#     refuses it. That is risk R9.
#   * `ssh root@localhost` NEEDS IdentitiesOnly=yes here for the same reason and
#     one more: the loopback key is the only one root accepts on 127.0.0.1, and an
#     ssh-agent would offer others first.
#   * The credential file's VALUE is never read into a shell variable that could
#     reach argv or a log line. Its size and a hash PREFIX are read instead; a
#     prefix cannot be inverted and still proves both machines hold the same file.
#   * `machines status` prints progress lines on stderr and JSON on stdout, and
#     it resolves the secretspec profile, so it needs SECRETSPEC_REASON and the
#     vault token in the environment or it fails with a reason error that looks
#     like a deployment error.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}
LOOPBACK_KEY=${LOOPBACK_KEY:-/home/hbohlen/.ssh/id_ed25519-op-dev}
LOOPBACK_FP=${LOOPBACK_FP:-SHA256:WgXJgoyQQ9pTLPVcWL31pnzNFPo/qR0zSPXmj6PEK8I}
CRED=${CRED:-/root/.config/op-sa-token}

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
osh() { ssh "${SSHOPTS[@]}" hbohlen@"$PUBLIC" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }
note() { printf '  NOTE %s\n' "$*"; }
check() { # check <label> <expected-substring> <actual>
  local exp act
  exp=$(printf '%s' "$2" | tr -s ' \t' ' '); act=$(printf '%s' "$3" | tr -s ' \t' ' ')
  if printf '%s' "$act" | grep -qF -- "$exp"; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n        expected: %s\n        actual:   %s\n' "$1" "$exp" \
         "$(printf '%s' "$act" | tr '\n' '|' | cut -c1-200)"; rc=1; fi
}
rc=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

[ -r "$KEY" ] || { printf 'FAIL: %s missing — materialize it (docs/install-netcup.md step 1; it needs an appended trailing newline)\n' "$KEY" >&2; exit 1; }

step "the host answers as root over the public path"
out=$(rsh 'hostname') || { printf '  FAIL cannot reach %s as root\n' "$PUBLIC"; exit 1; }
check "hostname" "netcup" "$out"
out=$(osh 'hostname'); check "the operator key still logs in (this change must not weaken the public path)" "netcup" "$out"

step "the checkout is the published revision (see scripts/self-deploy-drift.sh for the verdict)"
PUSHED=$(git -C "$REPO" ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}')
out=$(rsh "git -C $HOST_REPO rev-parse HEAD; git -C $HOST_REPO status --porcelain | head -20")
printf '%s\n' "$out" | sed 's/^/  /'
check "host HEAD == origin/main ($PUSHED)" "$PUSHED" "$(printf '%s' "$out" | head -1)"

step "the declared nix features, git and op are installed"
out=$(rsh 'grep -h "^experimental-features" /etc/nix/nix.conf; command -v git; command -v op')
printf '%s\n' "$out" | sed 's/^/  /'
check "experimental-features carries nix-command" "nix-command" "$out"
check "experimental-features carries flakes" "flakes" "$out"
check "git is on PATH" "/git" "$out"
check "the 1Password CLI is on PATH" "/op" "$out"

step "the store is read-write, because the remount unit ran at boot (risk R11)"
out=$(rsh 'systemctl is-active nix-store-remount-rw.service; systemctl show -p Result --value nix-store-remount-rw.service; findmnt -no OPTIONS /nix/store')
printf '%s\n' "$out" | sed 's/^/  /'
check "the remount unit is active" "active" "$(printf '%s' "$out" | sed -n 1p)"
check "the unit's result is success" "success" "$(printf '%s' "$out" | sed -n 2p)"
if printf '%s' "$out" | sed -n 3p | grep -qE '(^|,)rw(,|$)'; then printf '  OK   /nix/store is mounted rw\n'
else printf '  FAIL /nix/store is not mounted rw — the host can receive closures but cannot build one\n'; rc=1; fi

step "the loopback identity sits at the ONE declared path, root-owned 0600 (design D4)"
out=$(rsh "stat -c '%a %U:%G' $LOOPBACK_KEY 2>&1; ssh-keygen -y -f $LOOPBACK_KEY 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print \$2}'")
printf '%s\n' "$out" | sed 's/^/  /'
check "mode and owner" "600 root:root" "$(printf '%s' "$out" | sed -n 1p)"
check "fingerprint" "$LOOPBACK_FP" "$(printf '%s' "$out" | sed -n 2p)"

step "root accepts that key on the loopback, with no agent and no password"
out=$(rsh "ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts -i $LOOPBACK_KEY root@localhost 'id -u; hostname' 2>&1")
printf '%s\n' "$out" | sed 's/^/  /'
check "loopback login is uid 0" "0" "$(printf '%s' "$out" | head -1)"
check "loopback login reports the host's name" "netcup" "$(printf '%s' "$out" | tail -1)"

step "a store over the loopback answers as a remote (risk R9: NIX_SSHOPTS names the identity)"
out=$(rsh "NIX_SSHOPTS='-i $LOOPBACK_KEY -o IdentitiesOnly=yes' nix store info --store ssh://root@localhost 2>&1 | head -8")
printf '%s\n' "$out" | sed 's/^/  /'
check "the loopback store answers with a version" "Version:" "$out"
check "the loopback store is writable" "Writable: yes" "$out"

step "the credential is at rest, root-owned 0600, and matches the workstation's file (value never read)"
out=$(rsh "stat -c '%a %U:%G %s' $CRED 2>&1; sha256sum $CRED 2>/dev/null | cut -c1-16")
printf '%s\n' "$out" | sed 's/^/  /'
check "mode, owner and presence" "600 root:root" "$(printf '%s' "$out" | sed -n 1p)"
if [ -r "$HOME/.config/op-sa-token" ]; then
  here=$(sha256sum "$HOME/.config/op-sa-token" | cut -c1-16)
  printf '  workstation prefix: %s\n' "$here"
  check "the two files hold the same credential" "$(printf '%s' "$out" | sed -n 2p)" "$here"
else
  note "$HOME/.config/op-sa-token is absent here, so the prefixes were not compared"
fi

step "the running system records the loop it runs (task 7.4's real change, read back)"
# This is the fact 7.4 deploys: a declared file, not a mechanism, so that the
# loop is proved to CHANGE something rather than only to work on a no-op. The
# keys are checked as a set: the record is world-readable, and a field added to
# it later is a field that could carry something that should not be there.
lrbranch=$(sed -n 's/^BRANCH=${BRANCH:-\([^}]*\)}.*/\1/p' "$REPO/scripts/self-deploy-drift.sh" | head -1)
out=$(rsh "readlink /etc/netcup-self-deploy/loop.json; cat /etc/netcup-self-deploy/loop.json")
printf '%s\n' "$out" | sed 's/^/  /'
check "the running system carries the record" "/etc/static/netcup-self-deploy/loop.json" "$(printf '%s' "$out" | head -1)"
printf '%s' "$out" | tail -n +2 | python3 -c '
import json,sys
want={"repository","branch","checkout","targetOverride","loopbackKey","authored"}
try: d=json.loads(sys.stdin.read().strip())
except Exception as e: print("  FAIL the record is not JSON: %s"%e); sys.exit(1)
want_branch=sys.argv[1]
bad=[]
extra=set(d)-want
if extra: bad.append("unexpected keys %s"%sorted(extra))
if want-set(d): bad.append("missing keys %s"%sorted(want-set(d)))
if d.get("branch")!=want_branch: bad.append("branch is %r, the drift check compares %r"%(d.get("branch"),want_branch))
if d.get("targetOverride")!="machines.netcup.target.host:string root@localhost": bad.append("targetOverride is not the loopback override")
if bad: print("  FAIL "+"; ".join(bad)); sys.exit(1)
print("  OK   branch %r, the loopback override, and no key that should not be here"%want_branch)
' "$lrbranch" || rc=1

step "the host's own build of its own declaration is the running system"
out=$(rsh "cd $HOST_REPO && export SECRETSPEC_REASON='self-deploy verify: read the host deployment state' OP_SERVICE_ACCOUNT_TOKEN=\$(cat $CRED) NIX_SSHOPTS='-i $LOOPBACK_KEY -o IdentitiesOnly=yes' && ./bin/devenv machines status netcup -O machines.netcup.target.host:string root@localhost --no-tui 2>/dev/null; echo RC=\$?")
printf '%s\n' "$out" | grep -v '^RC=' | head -40 | sed 's/^/  /'
check "machines status exits 0" "RC=0" "$(printf '%s' "$out" | tail -1)"
printf '%s' "$out" | python3 -c '
import json,sys,re
raw=sys.stdin.read()
m=re.search(r"\{.*\}", raw, re.S)
if not m: print("  FAIL no JSON in machines status output"); sys.exit(1)
d=json.loads(m.group(0))
d=d.get("machines",{}).get("netcup", d.get("netcup", d))
for k in ("phase","outcome","previousSystem","requestedSystem","runningSystem"):
    if k in d: print("  %-16s %s"%(k,d[k]))
prev,req=d.get("previousSystem"),d.get("requestedSystem")
if d.get("outcome")=="succeeded" and prev==req:
    print("  OK   the last deploy succeeded and activated the requested system (not rolled back)")
else:
    print("  FAIL phase=%r outcome=%r previousSystem=%r requestedSystem=%r"%(d.get("phase"),d.get("outcome"),prev,req)); sys.exit(2)
' || rc=1

out=$(rsh 'readlink -f /run/current-system')
printf '  /run/current-system: %s\n' "$out"

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL CHECKS GREEN.\n'; else printf 'CHECKS FAILED (see the FAIL lines above).\n'; fi
exit "$rc"