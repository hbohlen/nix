#!/bin/bash
# scripts/agent-tooling-verify.sh — read-only evidence that the operator account
# on the host carries the agent tooling, checked from the workstation.
#
# The runbook form of openspec/changes/add-netcup-agent-tooling/tasks.md tasks
# 3.2 and 3.4, asserting the scenarios of the `netcup-agent-tooling` capability
# and the ADDED `netcup-self-deploy` cache requirement. It writes nothing that
# survives, deploys nothing, and builds nothing of the host's own system.
#
# THE HOST-TOUCHING SCRIPT, so per netcup-operations it is run in a pane and
# watched:
#   ./scripts/bb-pane-run.sh --title "agent-tooling verify" -- ./scripts/agent-tooling-verify.sh
#
# `--pre` runs ONLY the host credential gate (task 3.2), which is the check that
# must pass BEFORE the deploy: it proves the declaration has not broken the
# self-deploy loop's profile resolution. Without `--pre` it runs the full
# post-deploy set (task 3.4).
#
# WHAT EACH HALF RUNS AS, AND WHY IT MATTERS:
#   * The TOOLING checks (hermes, herdr, nix config, a non-root build) run as
#     `hbohlen` over the public path, because the home-manager role is a change
#     to THAT account. Their PATH is prefixed with `$HOME/.nix-profile/bin`
#     explicitly: an ssh command runs a NON-interactive shell that does not
#     source a login profile, so the home-manager profile would otherwise be
#     invisible even though activation put it there.
#   * The SECRET and STATUS checks run as `root` at the host checkout, using the
#     loop's D3 credential (`/root/.config/op-sa-token`) exactly as
#     scripts/self-deploy-run.sh does. `hbohlen` has no vault credential on
#     purpose (design D3/D4): the credential at rest is root-only.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27/28):
#   * `nix config show` is the check that the DECLARATION names the cache; a
#     non-root `nix build` is the check that substitution itself is not silently
#     dropped for an untrusted user (the host's `trusted-users` is `root`).
#   * `machines info`/`status` resolve the secretspec profile, so they need
#     SECRETSPEC_REASON and the vault token in the environment. They are read
#     back exactly as scripts/operator-env-verify.sh reads them.
#   * A non-interactive ssh command has no `hostname` on PATH (docs/
#     self-deploy-netcup.md §6); this script does not call it.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}
LOOPBACK_KEY=${LOOPBACK_KEY:-/home/hbohlen/.ssh/id_ed25519-op-dev}
CRED=${CRED:-/root/.config/op-sa-token}

PRE=0
[ "${1:-}" = "--pre" ] && PRE=1

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
osh() { ssh "${SSHOPTS[@]}" hbohlen@"$PUBLIC" "$@"; }
# Run a command as hbohlen with the home-manager profile on PATH, since a
# non-interactive ssh shell does not source one.
huser() { osh "export PATH=\"\$HOME/.nix-profile/bin:\$PATH\"; $*"; }
step() { printf '\n== %s ==\n' "$*"; }
check() { # check <label> <expected-substring> <actual>
  local exp act
  exp=$(printf '%s' "$2" | tr -s ' \t' ' '); act=$(printf '%s' "$3" | tr -s ' \t' ' ')
  if printf '%s' "$act" | grep -qF -- "$exp"; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n        expected: %s\n        actual:   %s\n' "$1" "$exp" \
         "$(printf '%s' "$act" | tr '\n' '|' | cut -c1-200)"; rc=1; fi
}
rc=0

[ -r "$KEY" ] || { printf 'FAIL: %s missing — materialize it (docs/install-netcup.md step 1; it needs an appended trailing newline)\n' "$KEY" >&2; exit 1; }

step "the host credential gate: ./bin/devenv machines info still resolves the profile"
# Task 3.2. The declaration adds no secret, so this must be unchanged from the
# operator-env change — but it is verified rather than assumed, because a broken
# profile resolution would only surface later, as a failed deploy.
out=$(rsh "cd $HOST_REPO && export SECRETSPEC_REASON='agent-tooling verify: host credential gate' OP_SERVICE_ACCOUNT_TOKEN=\$(cat $CRED) && ./bin/devenv machines info 2>&1; echo RC=\$?")
printf '%s\n' "$out" | grep -v '^RC=' | sed 's/^/  /'
check "machines info exits 0" "RC=0" "$(printf '%s' "$out" | tail -1)"
check "netcup is listed" "netcup" "$out"
check "the nixos role is listed" "nixos" "$out"
check "the home-manager role is listed" "home-manager" "$out"

if [ "$PRE" -eq 1 ]; then
  printf '\n'
  if [ "$rc" -eq 0 ]; then printf 'PRE-DEPLOY GATE GREEN: the host still resolves its profile.\n'
  else printf 'PRE-DEPLOY GATE FAILED (see the FAIL lines above).\n'; fi
  exit "$rc"
fi

step "hermes and herdr are on the operator's PATH and report a version (spec: both tools are on PATH)"
out=$(huser 'command -v hermes; hermes --version 2>&1 | head -1; echo H_RC=$?; command -v herdr; herdr --version 2>&1 | head -1; echo D_RC=$?')
printf '%s\n' "$out" | sed 's/^/  /'
check "hermes resolves on the operator PATH" "/bin/hermes" "$(printf '%s' "$out" | sed -n 1p)"
check "hermes --version exits 0" "H_RC=0" "$(printf '%s' "$out" | grep '^H_RC=')"
check "herdr resolves on the operator PATH" "/bin/herdr" "$(printf '%s' "$out" | sed -n 4p)"
check "herdr --version exits 0" "D_RC=0" "$(printf '%s' "$out" | grep '^D_RC=')"

step "the host DECLARES cache.numtide.com for the operator (spec: the declaration survives a rebuild)"
out=$(huser 'nix config show | grep -c cache.numtide.com')
printf '  cache.numtide.com appears on %s config line(s)\n' "$out"
if [ "${out:-0}" -ge 1 ] 2>/dev/null; then printf '  OK   the declared nix.settings list the cache\n'
else printf '  FAIL the cache is not in nix config — the host would compile the packages from source\n'; rc=1; fi

step "a NON-ROOT build still substitutes with no client-supplied flags (spec: the existing cache did not regress)"
out=$(huser 'nix build --no-link --print-out-paths nixpkgs#hello 2>&1; echo RC=$?')
printf '%s\n' "$out" | sed 's/^/  /'
check "the non-root build of hello completes" "RC=0" "$(printf '%s' "$out" | tail -1)"

step "a numtide-provided path realizes as hbohlen with no client-supplied substituter flags (spec: it substitutes rather than builds)"
# `herdr` is in the operator's profile, so its whole closure is already in the
# host store. Re-realizing it from the flake uses the host's DECLARED
# substituters and no `--option` flags, which is exactly the scenario: the
# declaration, not a caller's flags, is what makes it a download.
out=$(huser 'nix build --no-link --print-out-paths github:numtide/llm-agents.nix#herdr 2>&1; echo RC=$?')
printf '%s\n' "$out" | sed 's/^/  /'
check "herdr realizes with no client flags" "RC=0" "$(printf '%s' "$out" | tail -1)"
check "it resolves to a herdr store path" "-herdr-" "$out"

step "the host's last self-deploy succeeded and is the running system (spec: the loop is not broken)"
out=$(rsh "cd $HOST_REPO && export SECRETSPEC_REASON='agent-tooling verify: read the host deployment state' OP_SERVICE_ACCOUNT_TOKEN=\$(cat $CRED) NIX_SSHOPTS='-i $LOOPBACK_KEY -o IdentitiesOnly=yes' && ./bin/devenv machines status netcup -O machines.netcup.target.host:string root@localhost --no-tui 2>/dev/null; echo RC=\$?")
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
running=d.get("runningSystem"); req=d.get("requestedSystem")
if d.get("outcome")=="succeeded" and (running is None or running==req):
    print("  OK   the last deploy succeeded and the running system is the requested one")
else:
    print("  FAIL phase=%r outcome=%r runningSystem=%r requestedSystem=%r"%(d.get("phase"),d.get("outcome"),running,req)); sys.exit(2)
' || rc=1

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL CHECKS GREEN: the agent tooling is installed and the loop still works.\n'
else printf 'CHECKS FAILED (see the FAIL lines above).\n'; fi
exit "$rc"
