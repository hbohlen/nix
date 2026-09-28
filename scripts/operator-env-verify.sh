#!/bin/bash
# scripts/operator-env-verify.sh — read-only evidence that the operator account
# on the host has its user environment, checked from the workstation.
#
# The runbook form of openspec/changes/add-netcup-operator-env/tasks.md task 3.5,
# asserting the scenarios of the `netcup-operator-env` capability and the
# MODIFIED `netcup-self-deploy` cache scenario. It writes nothing that survives
# (one file created and deleted under ~/projects to prove writability), deploys
# nothing, and builds nothing of the host's own system.
#
# THE HOST-TOUCHING SCRIPT, so per netcup-operations it is run in a pane and
# watched:
#   ./scripts/bb-pane-run.sh --title "operator-env verify" -- ./scripts/operator-env-verify.sh
#
# WHAT EACH HALF RUNS AS, AND WHY IT MATTERS:
#   * The TOOLING checks (devenv, gh, ~/projects, nix config, a non-root build)
#     run as `hbohlen` over the public path, because the whole point of the
#     home-manager role is a change to THAT account. Their PATH is prefixed with
#     `$HOME/.nix-profile/bin` explicitly: an ssh command runs a NON-interactive
#     shell that does not source a login profile, so the home-manager profile
#     directory would otherwise be invisible even though activation put it there.
#   * The SECRET and STATUS checks run as `root` at the host checkout, using the
#     loop's D3 credential (`/root/.config/op-sa-token`) exactly as
#     scripts/self-deploy-run.sh does. `hbohlen` has no vault credential on
#     purpose (design D3/D4): the credential at rest is root-only. This is the
#     identity design R3 asks about — if root's read-only credential cannot read
#     `GH_TOKEN`, the self-deploy loop is broken by the declaration.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27/28):
#   * `nix-build -p hello` DOES NOT EXIST. `-p`/`--packages` is a `nix-shell`
#     flag, and Determinate Nix 3.21.1 rejects it for `nix-build` with
#     `unrecognised flag '-p'` (measured 2026-09-28 on the workstation; the host
#     runs the same nixpkgs line). The tasks file named that command; this script
#     uses the equivalent that the host's Nix actually supports —
#     `nix build --no-link --print-out-paths nixpkgs#hello` — which still proves
#     the scenario: a non-root user substitutes with NO client-supplied
#     substituter flags. `nix config show` is the check that the DECLARATION
#     names devenv.cachix.org; this build is the check that substitution itself
#     is not silently dropped for an untrusted user.
#   * `machines status` prints progress on stderr and JSON on stdout, and
#     resolves the secretspec profile, so it needs SECRETSPEC_REASON and the
#     vault token in the environment. It is read back exactly as
#     scripts/self-deploy-verify.sh reads it.
#   * A non-interactive ssh command has no `hostname` on PATH (docs/
#     self-deploy-netcup.md §6); this script does not call it.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}
LOOPBACK_KEY=${LOOPBACK_KEY:-/home/hbohlen/.ssh/id_ed25519-op-dev}
CRED=${CRED:-/root/.config/op-sa-token}
HM_DEVENV=${HM_DEVENV:-/home/hbohlen/.nix-profile/bin/devenv}

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
osh() { ssh "${SSHOPTS[@]}" hbohlen@"$PUBLIC" "$@"; }
# Run a command as hbohlen with the home-manager profile on PATH, since a
# non-interactive ssh shell does not source one.
huser() { osh "export PATH=\"\$HOME/.nix-profile/bin:\$PATH\"; $*"; }
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

want_version=$("./bin/devenv" --version 2>&1 | awk '{print $2}')
# Compare the BASE version only: the home-manager package is derived from the
# locked input's path+narHash (design D2), which carries no flake rev metadata,
# so it reports `2.4.0` where this workstation's binary reports `2.4.0+b904dcb`.
# The spec scenario asks for "the same version, 2.4.0 or newer"; the source
# revision is proved separately by the `machines` subcommand check below.
want_base=${want_version%%+*}
printf 'workstation bin/devenv version: %s (base %s)\n' "$want_version" "$want_base"

step "the operator account is reachable over the public path"
out=$(huser 'id -un')
check "the operator key logs in as hbohlen" "hbohlen" "$out"

step "devenv is on hbohlen's PATH and reports the same version as bin/devenv (spec: both names agree)"
out=$(huser 'command -v devenv; devenv --version')
printf '%s\n' "$out" | sed 's/^/  /'
check "devenv resolves on the operator PATH" "/devenv" "$(printf '%s' "$out" | sed -n 1p)"
got_base=$(printf '%s' "$out" | sed -n 2p | awk '{print $2}' | cut -d+ -f1)
if [ "$got_base" = "$want_base" ]; then printf '  OK   devenv --version base %s matches bin/devenv (both 2.4.0)\n' "$got_base"
else printf '  FAIL devenv --version base is %s, expected %s\n' "$got_base" "$want_base"; rc=1; fi

step "the host checkout's own bin/devenv agrees too (the pinned toolchain is present)"
out=$(rsh "cd $HOST_REPO && ./bin/devenv --version 2>&1")
printf '%s\n' "$out" | sed 's/^/  /'
check "host ./bin/devenv --version matches the operator's bare devenv" "$want_version" "$out"

step "the operator's devenv is the locked input's package, not pkgs.devenv (spec: not the nixpkgs one)"
# The HM profile's devenv package is a symlink tree; its version string is the
# observable proof. pkgs.devenv on this nixpkgs is 2.3.1 and has no `machines`
# subcommand, so a wrong source fails the version check above and the
# `machines --help` check here.
out=$(huser 'devenv machines --help >/dev/null 2>&1; echo MACHINES_RC=$?')
check "bare devenv has the machines subcommand (not the 2.3.1 nixpkgs package)" "MACHINES_RC=0" "$out"

step "gh is installed for the operator"
out=$(huser 'command -v gh; gh --version | head -1')
printf '%s\n' "$out" | sed 's/^/  /'
check "gh resolves on the operator PATH" "/gh" "$(printf '%s' "$out" | sed -n 1p)"
check "gh --version reports a version" "gh version" "$(printf '%s' "$out" | sed -n 2p)"

step "~/projects is a real, writable directory owned by hbohlen (spec: not a store symlink)"
out=$(huser 'ls -ld /home/hbohlen/projects')
printf '%s\n' "$out" | sed 's/^/  /'
check "the directory exists and is owned by hbohlen" "hbohlen" "$out"
rl=$(huser 'readlink /home/hbohlen/projects || true')
if [ -z "$rl" ]; then printf '  OK   readlink is empty (a real directory, not a store symlink)\n'
else printf '  FAIL ~/projects is a symlink to %s\n' "$rl"; rc=1; fi
out=$(huser 'set -e; f=/home/hbohlen/projects/.operator-env-verify.$$; touch "$f"; test -f "$f"; rm -f "$f"; echo WRITABLE')
check "the operator can create and delete a file in it" "WRITABLE" "$out"

step "the host DECLARES devenv.cachix.org (spec: the cache declaration survives a rebuild)"
out=$(huser 'nix config show | grep -c devenv.cachix.org')
printf '  devenv.cachix.org appears on %s config line(s)\n' "$out"
if [ "${out:-0}" -ge 1 ] 2>/dev/null; then printf '  OK   the declared nix.settings list the cache\n'
else printf '  FAIL the cache is not in nix config — an untrusted user'\''s client flags are silently dropped\n'; rc=1; fi

step "a NON-ROOT build substitutes with no client-supplied substituter flags (spec: the cache scenario)"
out=$(huser 'nix build --no-link --print-out-paths nixpkgs#hello 2>&1; echo RC=$?')
printf '%s\n' "$out" | sed 's/^/  /'
check "the non-root build of hello completes" "RC=0" "$(printf '%s' "$out" | tail -1)"

step "GH_TOKEN resolves for gh as the loop's credential, per use, value never read (spec: auth at the moment of use)"
# `secretspec run` inherits this remote shell's PATH, and this command runs as
# `root`, whose HOME is /root — so `$HOME/.nix-profile/bin` would be the WRONG
# profile and `gh` would be missing (measured: that is exactly how this check
# failed, twice, on 2026-09-28). The operator's profile is named absolutely.
out=$(rsh "cd $HOST_REPO && export PATH=\"/home/hbohlen/.nix-profile/bin:\$PATH\" SECRETSPEC_REASON='operator-env verify: prove GH_TOKEN resolves for gh' OP_SERVICE_ACCOUNT_TOKEN=\$(cat $CRED) && \$(readlink -f .devenv-toolchain)/bin/secretspec run --reason 'operator-env verify: gh auth status' -- gh auth status 2>&1; echo RC=\$?")
printf '%s\n' "$out" | grep -v '^RC=' | sed 's/^/  /'
check "gh reports the authenticated account" "Logged in to github.com account hbohlen" "$out"
check "the authenticated invocation exits 0" "RC=0" "$(printf '%s' "$out" | tail -1)"

step "the host's last self-deploy succeeded and is the running system (spec: the loop is not broken)"
out=$(rsh "cd $HOST_REPO && export SECRETSPEC_REASON='operator-env verify: read the host deployment state' OP_SERVICE_ACCOUNT_TOKEN=\$(cat $CRED) NIX_SSHOPTS='-i $LOOPBACK_KEY -o IdentitiesOnly=yes' && ./bin/devenv machines status netcup -O machines.netcup.target.host:string root@localhost --no-tui 2>/dev/null; echo RC=\$?")
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
# A SUCCESSFUL REAL CHANGE has previousSystem != requestedSystem — that is the
# point of a deploy, not a failure. The signals to require are: the deploy
# outcome succeeded, and the RUNNING system is the one it requested.
running=d.get("runningSystem")
req=d.get("requestedSystem")
if d.get("outcome")=="succeeded" and (running is None or running==req):
    if running==req: print("  OK   the last deploy succeeded and the running system is the requested one")
    else: print("  OK   the last deploy succeeded (%s; runningSystem not reported)"%d.get("phase"))
else:
    print("  FAIL phase=%r outcome=%r runningSystem=%r requestedSystem=%r"%(d.get("phase"),d.get("outcome"),running,req)); sys.exit(2)
' || rc=1

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL CHECKS GREEN: the operator environment is in place and the loop still works.\n'
else printf 'CHECKS FAILED (see the FAIL lines above).\n'; fi
exit "$rc"
