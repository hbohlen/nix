#!/bin/bash
# scripts/self-deploy-host.sh — the workstation-side entry to the host-side loop.
#
# Runs IN A PANE, so the operator watches the host rebuild itself instead of
# reading it back afterwards:
#   ./scripts/bb-pane-run.sh --title "self-deploy from the host" -- ./scripts/self-deploy-host.sh
#
# WHAT IT DOES, IN ORDER, AND WHY IN THAT ORDER:
#   1. scripts/self-deploy-drift.sh — the host must already hold the PUBLISHED
#      revision. A deploy run on a checkout that is behind, or that carries an
#      edit only the host has, would build a system nobody can reproduce, and it
#      would report success while doing it. Risk R5.
#   2. `git pull --ff-only` on the host — the only write this script makes that
#      is not the deploy itself, and it can only fast-forward: a divergent host
#      checkout is a question for a person, not something to merge through.
#   3. scripts/self-deploy-run.sh — ON the host, over ssh, under the host's own
#      loopback identity. That file sets the three variables the step needs and
#      reads back what the target recorded.
#   4. the verdict, read from the host: the running system path the deploy
#      requested, so a pane's tail shows whether it landed or rolled back.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * The host's checkout is root-owned; only root can pull it, and the deploy
#     runs as root anyway.
#   * THE HOST HAS NO PUSH CREDENTIAL. The repository is public so the CLONE
#     needs no credential, and a push from the host fails for exactly that
#     reason. Edits are therefore AUTHORED on the workstation and PUSHED from it;
#     the host only ever pulls. See docs/self-deploy-netcup.md.
#   * The remote command is passed as a QUOTED ARRAY element by
#     scripts/bb-pane-run.sh, so a shell inside it is evaluated by the remote
#     shell — which is what lets `bash scripts/self-deploy-run.sh` run with the
#     host's cwd rather than the workstation's.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}
BRANCH=${BRANCH:-main}

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }
fail() { printf '\nSELF-DEPLOY ABORTED: %s\n' "$*" >&2; exit 1; }

[ -r "$KEY" ] || fail "$KEY missing — materialize it (docs/install-netcup.md step 1)"

step "1. the drift check (the host must hold the published revision)"
"$REPO/scripts/self-deploy-drift.sh" || fail "the host's checkout is not the published revision — fix that first, then run this again"

step "2. the host updates its checkout, fast-forward only"
rsh "git -C $HOST_REPO pull --ff-only" || fail "git pull --ff-only on the host"
rsh "git -C $HOST_REPO log --oneline -1; git -C $HOST_REPO status --porcelain | head"

step "3. the deploy, run ON the host against root@localhost"
rsh "cd $HOST_REPO && bash scripts/self-deploy-run.sh"
rc=$?
printf '  remote exit %s\n' "$rc"

step "4. the verdict, read from the host"
rsh 'readlink -f /run/current-system; hostname; uptime' | sed 's/^/  /'

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'SELF-DEPLOY OK: the host built and activated its own declaration.\n'
else printf 'SELF-DEPLOY FAILED (remote exit %s) — read the pane above; the running system is printed above, and a failed activation is rolled back rather than half-applied.\n' "$rc"; fi
exit "$rc"