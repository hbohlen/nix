#!/usr/bin/env bash
# scripts/self-deploy-drift.sh — is the host's checkout the published revision?
#
# The one gate before a deploy. This host holds a checkout of this repository and
# rebuilds itself from it, so the failure this check exists for is an edit made
# here and never pushed: a hand-maintained copy of a declaration that lives
# elsewhere. Nothing else in the loop notices — the deploy would run happily, and
# the difference would only surface the next time the host is rebuilt from the
# remote, or never.
#
# It exits 0 only when this checkout IS the published revision with nothing
# uncommitted. Both failure modes need an operator, not a script: a dirty tree
# has to be committed and pushed, and a checkout that is behind has to pull. The
# check merges, resets and discards nothing — it only reads.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27 / 2026-09-28):
#   * The checkout is OPERATOR-owned at /home/hbohlen/nix. The read below still
#     runs AS ROOT over ssh, because the loopback key is root's — safe here:
#     `rev-parse`, `log` and `status` create no objects. The command that DOES
#     write objects (`git pull`) runs in the owner's name when it is run at all,
#     so root-owned files never appear under .git.
#   * `git status --porcelain` on a healthy checkout prints NOTHING: .devenv/,
#     .devenv-toolchain and .machines/ are gitignored, so the toolchain symlink
#     and the facter report are not mistaken for drift.
#   * The comparison is against the REMOTE (`git ls-remote origin`), not against
#     the local bookmark: "the pushed revision" is what a fresh clone would get,
#     and a local-only commit is not published at all.
#   * The commit ranges are read with THIS machine's object store: a checkout
#     that is behind has not fetched the published revision, so
#     `git log HEAD..origin/main` prints nothing even when commits are missing —
#     measured on this check's first real run.
#   * Pushing from this host works (`secretspec run -- git push origin main`,
#     README.md). What this check still refuses is a commit that is NOT
#     PUBLISHED: push before deploying. The CLONE needs no credential — the
#     repository is public.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
PUBLIC=${PUBLIC:-152.53.92.126}
BRANCH=${BRANCH:-main}
HOST_REPO=${HOST_REPO:-/home/hbohlen/nix}

for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'; exit 0 ;;
    *) printf 'self-deploy-drift.sh: unexpected argument %s (this check has no options)\n' "$a" >&2; exit 2 ;;
  esac
done

SSHOPTS=(-F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
         -o StrictHostKeyChecking=accept-new -i "$KEY")
rsh() { ssh "${SSHOPTS[@]}" root@"$PUBLIC" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }
fail() { printf '\nDRIFT CHECK FAILED: %s\n' "$*" >&2; exit 1; }

[ -r "$KEY" ] || fail "$KEY missing — the loopback identity lives at that path, mode 0600"
[ -d "$REPO/.git" ] || fail "$REPO is not a git checkout"

step "the published revision of the remote"
PUSHED=$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
[ -n "$PUSHED" ] || fail "cannot read refs/heads/$BRANCH from origin — is the remote reachable?"
printf '  origin/%s: %s\n' "$BRANCH" "$PUSHED"

step "this checkout, read over the loopback as root"
out=$(rsh "git -C $HOST_REPO rev-parse HEAD 2>&1; git -C $HOST_REPO log --oneline -1 2>&1; git -C $HOST_REPO status --porcelain 2>&1") \
  || fail "cannot reach $PUBLIC as root, or $HOST_REPO is not a git checkout"
HEAD_REV=$(printf '%s\n' "$out" | sed -n 1p)
HEAD_SUBJ=$(printf '%s\n' "$out" | sed -n 2p)
DIRTY=$(printf '%s\n' "$out" | sed -n '3,$p' | sed '/^$/d')
printf '  host HEAD:     %s\n' "$HEAD_REV"
printf '  host subject:  %s\n' "$HEAD_SUBJ"

step "the verdict"
rc=0

# 1. Uncommitted work: no pull can absorb it, and it is the shape this check
#    exists for — a declaration that exists only on this machine.
if [ -z "$DIRTY" ]; then
  printf '  OK   no uncommitted difference on the host\n'
else
  printf '  FAIL the host tree carries uncommitted differences:\n'
  printf '%s\n' "$DIRTY" | sed 's/^/         /'
  printf '       If it was a deliberate probe, discard it:\n'
  printf '         git -C %s checkout -- .\n' "$HOST_REPO"
  printf '       If it is real work, commit and push it (README.md):\n'
  printf '         git add -A && git commit -m "<action> | <subject>"\n'
  printf '         OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) secretspec run -- git push origin main\n'
  rc=1
fi

# 2. The revision itself.
if [ "$HEAD_REV" = "$PUSHED" ]; then
  printf '  OK   the host is at the published revision\n'
elif git -C "$REPO" merge-base --is-ancestor "$HEAD_REV" "$PUSHED" 2>/dev/null; then
  printf '  FAIL the host is BEHIND the published revision:\n'
  git -C "$REPO" log --oneline "$HEAD_REV..$PUSHED" 2>/dev/null | sed 's/^/         /'
  rc=1
else
  # Not an ancestor either way: the checkout holds commits nobody else has, or
  # the two histories diverged. Never a pull's business to resolve.
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
  printf '\nDRIFT: settle this before deploying.\n'
  printf '  behind the published revision:  git -C %s pull --ff-only\n' "$HOST_REPO"
  printf '  uncommitted work:               commit and push it, then run this again\n'
fi
exit "$rc"
