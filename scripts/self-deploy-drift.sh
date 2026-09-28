#!/bin/bash
# scripts/self-deploy-drift.sh — is the host's checkout the published revision?
#
# Risk R5, and task 8.3. The host holds a checkout of this repository and is
# expected to rebuild itself from it. The failure this check exists for is an
# edit made in place on the host and never pushed: that turns the host into a
# hand-maintained copy of a declaration that lives somewhere else, which is the
# exact thing the single-declaration rule (design D2) exists to prevent. Nothing
# else in the loop notices — the host would deploy happily, and the difference
# would only surface the next time the host is rebuilt from the remote, or never.
#
# IT ALSO FAILS ON DIRTY WORK, deliberately, including a file the operator meant
# to change: the host is not where edits are authored, it is where the pushed
# revision is applied. That is why the verdict is about the revision AND the
# worktree, and why the check prints the divergent paths instead of a count.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * The host's checkout is root-owned at /home/hbohlen/nix, because the deploy
#     runs as root and `git pull` must be able to write there.
#   * `git status --porcelain` on a healthy host prints NOTHING: .devenv/,
#     .devenv-toolchain and .machines/ are gitignored, so the toolchain symlink
#     and the facter report are not mistaken for drift.
#   * The comparison is against the REMOTE (`git ls-remote origin`), not against
#     the local bookmark: "the pushed revision" is what a fresh clone would get,
#     and a local-only commit is not published at all.
#   * The host has no push credential — measured in this change's task 7.4:
#     the repository is PUBLIC so the CLONE needs none, and a push from the host
#     fails for exactly that reason. Editing therefore happens on the workstation
#     and the host only ever pulls; see docs/self-deploy-netcup.md.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
BRANCH=${BRANCH:-main}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }
fail() { printf '\nDRIFT CHECK FAILED: %s\n' "$*" >&2; exit 1; }

[ -r "$KEY" ] || fail "$KEY missing — materialize it (docs/install-netcup.md step 1)"
[ -d "$REPO/.git" ] || fail "$REPO is not a git checkout"

step "the published revision of the remote"
PUSHED=$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
[ -n "$PUSHED" ] || fail "cannot read refs/heads/$BRANCH from origin — is the remote reachable from this workstation?"
printf '  origin/%s: %s\n' "$BRANCH" "$PUSHED"

step "the host's checkout"
out=$(rsh "git -C $HOST_REPO rev-parse HEAD 2>&1; git -C $HOST_REPO log --oneline -1 2>&1; git -C $HOST_REPO status --porcelain 2>&1") \
  || fail "cannot reach $PUBLIC as root, or $HOST_REPO is not a git checkout on the host"
HEAD_REV=$(printf '%s\n' "$out" | sed -n 1p)
HEAD_SUBJ=$(printf '%s\n' "$out" | sed -n 2p)
DIRTY=$(printf '%s\n' "$out" | sed -n '3,$p' | sed '/^$/d')
printf '  host HEAD:     %s\n' "$HEAD_REV"
printf '  host subject:  %s\n' "$HEAD_SUBJ"

step "the verdict"
rc=0
if [ "$HEAD_REV" = "$PUSHED" ]; then
  printf '  OK   the host is at the published revision\n'
else
  printf '  FAIL the host is NOT at the published revision\n'
  printf '       host:     %s\n       published: %s\n' "$HEAD_REV" "$PUSHED"
  # The two sides are compared with the WORKSTATION's object store: the host has
  # not fetched the published revision (that is the point), so `git log
  # HEAD..origin/main` on the host prints nothing even when commits are missing —
  # measured 2026-09-28 on the first real drift this check saw.
  missing=$(git -C "$REPO" log --oneline "$HEAD_REV..$PUSHED" 2>/dev/null)
  if [ -n "$missing" ]; then
    printf '       commits the host does not have yet:\n'; printf '%s\n' "$missing" | sed 's/^/         /'
  else
    printf '       the published revision is not a descendant of the host revision —\n'
    printf '       the host carries commits that are not published:\n'
    ahead=$(git -C "$REPO" log --oneline "$PUSHED..$HEAD_REV" 2>/dev/null)
    if [ -n "$ahead" ]; then printf '%s\n' "$ahead" | sed 's/^/         /'
    else printf '         (neither range is readable here — the two revisions have diverged)\n'; fi
  fi
  rc=1
fi
if [ -z "$DIRTY" ]; then
  printf '  OK   no uncommitted difference on the host\n'
else
  printf '  FAIL the host tree carries uncommitted differences:\n'
  printf '%s\n' "$DIRTY" | sed 's/^/         /'
  printf '       (D)iscarded with `git -C %s checkout -- .` if it was a probe,\n' "$HOST_REPO"
  printf '       otherwise it is work that exists ONLY on the host and belongs in\n'
  printf '       the repository — see docs/self-deploy-netcup.md §"where edits are made".\n'
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  printf '\nNO DRIFT: the host builds from the published revision.\n'
else
  printf '\nDRIFT: bring the host to the published revision before deploying from it.\n'
  printf '  on the host:  cd %s && git pull --ff-only\n' "$HOST_REPO"
fi
exit "$rc"