#!/usr/bin/env bash
# scripts/self-deploy-host.sh — the workstation-side entry to the host-side loop.
#
# Runs IN A PANE, so the operator watches the host rebuild itself instead of
# reading it back afterwards:
#   ./scripts/bb-pane-run.sh --title "self-deploy from the host" -- ./scripts/self-deploy-host.sh
#
# `--probe-uncommitted` IS THE ROLLBACK TEST'S DOOR (task 7.5) and nothing else's:
# it lets a deliberately uncommitted edit on the host through the dirty gate, so
# an activation can be made to fail on purpose and the rollback observed. The
# revision check is not relaxed by it. See docs/self-deploy-netcup.md.
#
# WHAT IT DOES, IN ORDER, AND WHY IN THAT ORDER:
#   1. scripts/self-deploy-drift.sh --fast-forwardable — the host must be CLEAN,
#      and the published revision must descend from what it holds. It is normally
#      BEHIND (a push just happened — that is why this script is being run), and
#      behind is fine here because step 2 fixes exactly that. What is not fine,
#      and stops the run, is an edit only the host has: that would build a system
#      nobody can reproduce, while reporting success. Risk R5.
#   2. `git pull --ff-only` on the host — the only write this script makes that
#      is not the deploy itself, and it can only fast-forward: a divergent host
#      checkout is a question for a person, not something to merge through. Then
#      the STRICT drift check again, which is the state a reader should expect
#      when a deploy lands.
#   3. scripts/self-deploy-run.sh — ON the host, over ssh, under the host's own
#      loopback identity. That file sets the three variables the step needs and
#      reads back what the target recorded.
#   4. the verdict, read from the host: the running system path the deploy
#      requested, so a pane's tail shows whether it landed or rolled back.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * The host's checkout is OPERATOR-owned at /home/hbohlen/nix (changed
#     2026-09-28, when the loop started running from this machine as hbohlen).
#     The remote commands here are still REACHED as root — the loopback key is
#     root's — so the pull is executed in the owner's name: a root `git pull`
#     creates root-owned files under .git/objects, and hbohlen's next write then
#     fails with EACCES. One tree, one writer.
#   * THE HOST PUSHES TOO, SINCE 2026-09-28 (it did not before): the credential
#     path is `OP_SERVICE_ACCOUNT_TOKEN=… secretspec run -- git push origin main`
#     — `gh auth setup-git` supplies the helper, the vault supplies GH_TOKEN for
#     that invocation only, nothing is stored. A bare `git push` still fails for
#     want of a username; that is what "no push credential" used to mean. See
#     docs/self-deploy-netcup.md §1.
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

# --probe-uncommitted IS THE ROLLBACK TEST'S DOOR (task 7.5). The probe that
# makes an activation fail is deliberately uncommitted ON THE HOST, so the dirty
# gate has to stand aside for exactly that run. The revision check is NOT
# relaxed: the run still builds from the published revision, so the probe is the
# only difference between what runs and what is published.
DRIFT_ARGS=()
if [ "${1:-}" = "--probe-uncommitted" ]; then
  DRIFT_ARGS+=(--allow-dirty)
  printf '\n*** PROBE RUN: an uncommitted edit on the host is EXPECTED and is about to be\n'
  printf '*** deployed to watch it fail. This is the rollback test. Discard the probe\n'
  printf '*** afterwards with:  ssh root@%s "git -C %s checkout -- ."\n' "$PUBLIC" "$HOST_REPO"
elif [ -n "${1:-}" ]; then
  fail "unknown argument $1 (only --probe-uncommitted is accepted)"
fi

step "1. the drift check (the host must be clean, and able to reach the published revision)"
"$REPO/scripts/self-deploy-drift.sh" --fast-forwardable "${DRIFT_ARGS[@]+"${DRIFT_ARGS[@]}"}" \
  || fail "the host carries uncommitted work, or commits nobody else has — settle that before deploying from it (see the check's output above)"

step "2. the host updates its checkout, fast-forward only"
# IN THE OWNER'S NAME (measured 2026-09-28): `sudo -n -Hu hbohlen` from root.
# Reachable only as root — the loopback key is root's — but a root `git pull`
# writes root-owned objects into an operator-owned tree, and hbohlen's next
# commit would then fail with EACCES.
rsh "sudo -n -Hu hbohlen git -C $HOST_REPO pull --ff-only" || fail "git pull --ff-only on the host"
rsh "sudo -n -Hu hbohlen git -C $HOST_REPO log --oneline -1; sudo -n -Hu hbohlen git -C $HOST_REPO status --porcelain | head"
"$REPO/scripts/self-deploy-drift.sh" "${DRIFT_ARGS[@]+"${DRIFT_ARGS[@]}"}" \
  || fail "the host is still not at the published revision after pulling — the strict check above says why"

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