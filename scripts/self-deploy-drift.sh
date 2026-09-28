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
# TWO MODES, BECAUSE "BEHIND" AND "DIRTY" ARE NOT THE SAME QUESTION:
#
#   scripts/self-deploy-drift.sh
#       Strict. The host must BE the published revision and carry no uncommitted
#       difference. This is the mode to read before a deploy: after
#       scripts/self-deploy-host.sh has pulled, this must be green.
#
#   scripts/self-deploy-drift.sh --fast-forwardable
#       The host must be able to REACH the published revision by pulling: it is
#       clean, and the published revision descends from what it holds. Being
#       behind is the normal state of a host that has just seen a push — it is
#       what `git pull --ff-only` is for — so this mode reports it as a NOTE and
#       exits 0. Dirty work and unpublished host commits are failures in BOTH
#       modes, because neither can be fixed by pulling.
#
# Neither mode merges, resets or discards anything. The check only reads.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27 / 2026-09-28):
#   * The host's checkout is root-owned at /home/hbohlen/nix, because the deploy
#     runs as root and `git pull` must be able to write there.
#   * `git status --porcelain` on a healthy host prints NOTHING: .devenv/,
#     .devenv-toolchain and .machines/ are gitignored, so the toolchain symlink
#     and the facter report are not mistaken for drift.
#   * The comparison is against the REMOTE (`git ls-remote origin`), not against
#     the local bookmark: "the pushed revision" is what a fresh clone would get,
#     and a local-only commit is not published at all.
#   * The commit ranges are read with the WORKSTATION's object store. The host
#     has not fetched the published revision (that is the point of being behind),
#     so `git log HEAD..origin/main` ON THE HOST prints nothing even when commits
#     are missing — measured on this check's first real run.
#   * The host has no push credential: the repository is PUBLIC, so the CLONE
#     needs none, and a push from the host fails for exactly that reason. Edits
#     are therefore authored on the workstation and the host only ever pulls; see
#     docs/self-deploy-netcup.md.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
BRANCH=${BRANCH:-main}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}

MODE=strict
for a in "$@"; do
  case "$a" in
    --fast-forwardable) MODE=lax ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'self-deploy-drift.sh: unexpected argument %s\n' "$a" >&2; exit 2 ;;
  esac
done

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }
note() { printf '  NOTE %s\n' "$*"; }
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

step "the verdict (mode: $MODE)"
rc=0

# 1. Uncommitted work. A failure in both modes: no pull can absorb it, and it is
#    the shape risk R5 warns about — a declaration that exists only on the host.
if [ -z "$DIRTY" ]; then
  printf '  OK   no uncommitted difference on the host\n'
else
  printf '  FAIL the host tree carries uncommitted differences:\n'
  printf '%s\n' "$DIRTY" | sed 's/^/         /'
  printf '       If it was a deliberate probe, discard it:\n'
  printf '         ssh root@%s "git -C %s checkout -- ."\n' "$PUBLIC" "$HOST_REPO"
  printf '       If it is real work, it belongs in the repository on the workstation:\n'
  printf '       the host is not where edits are authored (docs/self-deploy-netcup.md).\n'
  rc=1
fi

# 2. The revision itself.
if [ "$HEAD_REV" = "$PUSHED" ]; then
  printf '  OK   the host is at the published revision\n'
elif git -C "$REPO" merge-base --is-ancestor "$HEAD_REV" "$PUSHED" 2>/dev/null; then
  behind=$(git -C "$REPO" log --oneline "$HEAD_REV..$PUSHED" 2>/dev/null)
  if [ "$MODE" = lax ]; then
    note "the host is BEHIND the published revision and can fast-forward to it:"
    printf '%s\n' "$behind" | sed 's/^/         /'
    note "a pull brings it forward; the strict check runs after that pull"
  else
    printf '  FAIL the host is BEHIND the published revision:\n'
    printf '%s\n' "$behind" | sed 's/^/         /'
    rc=1
  fi
else
  # Not an ancestor either way: the host holds commits nobody else has, or the
  # two histories diverged. Never a pull's business to resolve.
  printf '  FAIL the published revision is not a descendant of the host revision\n'
  ahead=$(git -C "$REPO" log --oneline "$PUSHED..$HEAD_REV" 2>/dev/null)
  if [ -n "$ahead" ]; then
    printf '       the host holds commits that are NOT published:\n'
    printf '%s\n' "$ahead" | sed 's/^/         /'
  else
    printf '       (no readable range: the two revisions have diverged)\n'
  fi
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  printf '\nNO DRIFT: the host holds the published revision, with nothing uncommitted.\n'
else
  printf '\nDRIFT: settle this before deploying from the host.\n'
  printf '  a host that is merely behind:  ssh root@%s "git -C %s pull --ff-only"\n' "$PUBLIC" "$HOST_REPO"
fi
exit "$rc"