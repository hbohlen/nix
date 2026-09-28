#!/usr/bin/env bash
# scripts/self-deploy-run.sh — the deploy step of the loop, RUN ON THE HOST.
#
# This is the file that makes the change's headline true: the host rebuilds
# itself from the revision it holds, over its own loopback, with no workstation,
# no vault session and no long-lived credential of the vault's on the host.
#
# IT IS NOT STARTED BY HAND ON THE HOST. The workstation-side entry point is
# scripts/self-deploy-host.sh, which checks for drift first and then runs this
# file over ssh; use that, in a pane:
#   ./scripts/bb-pane-run.sh --title "self-deploy from the host" -- ./scripts/self-deploy-host.sh
#
# WHY IT EXISTS AS A FILE AND NOT AS A LINE IN THE PANE: the environment this
# step needs is three variables that fail in three different ways when they are
# missing, and every one of those failures looks like a broken host:
#   * NIX_SSHOPTS        — without it the store copy over ssh://root@localhost is
#                          refused by the target ("lacks a signature by a trusted
#                          key", or a key mismatch). Risk R9.
#   * SECRETSPEC_REASON  — require_reason = true, and devenv forwards no reason
#                          flag of its own, so `machines` dies with "Accessing
#                          secrets requires a reason".
#   * OP_SERVICE_ACCOUNT_TOKEN — without it 1Password cannot resolve the profile
#                          and `machines` fails with a provider error that reads
#                          like a machine error.
# THE TOKEN IS READ FROM A ROOT-OWNED 0600 FILE (task 6.1) AND NEVER PRINTED.
# As root that is /root/.config/op-sa-token; run as the operator (hbohlen), who
# cannot read root's home, it is the operator's own copy at
# ~/.config/op-sa-token — same mode, same read-only service-account token.
# Measured 2026-09-28: the path is chosen by readability, so the same script
# works for both callers and neither caller needs the other's home.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * The deployed host's /nix/store is rw only because nix-store-remount-rw
#     ran at boot. If a build here fails with a read-only store, that unit is the
#     first suspect, not nix itself (risk R11).
#   * `--yes` is not decoration: without it the plan is printed and the deploy
#     waits at `Apply this fleet plan? [y/N]` for an answer nothing in a pane
#     will type. `--no-tui` keeps the output readable in a pane.
#   * The target override `-O machines.netcup.target.host:string root@localhost`
#     redirects THIS INVOCATION only; hosts/netcup/*.nix is not edited, so the
#     declaration still names the public address for a deploy run elsewhere.
#   * `machines status` is read back with the SAME override, because status reads
#     the target's own state — without it, it reports on a host this run never
#     touched.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOOPBACK_KEY=${LOOPBACK_KEY:-/home/hbohlen/.ssh/id_ed25519-op-dev}
if [ -z "${CRED:-}" ]; then
  if [ -r /root/.config/op-sa-token ]; then CRED=/root/.config/op-sa-token
  else CRED=${HOME:?HOME is unset}/.config/op-sa-token; fi
fi
TARGET_OVERRIDE="machines.netcup.target.host:string root@localhost"

step() { printf '\n== %s ==\n' "$*"; }
fail() { printf '\nSELF-DEPLOY FAILED: %s\n' "$*" >&2; exit 1; }

devenv() { (cd "$REPO" && ./bin/devenv "$@"); }
status() { devenv machines status netcup -O $TARGET_OVERRIDE --no-tui; }

step "this is running on the host the deploy targets"
# The loopback target is only the right target FROM the host. Deploying this
# script's command from the workstation would redirect a deploy back to the
# workstation's own localhost, which is not a NixOS machine at all.
# The name comes from /proc, NOT from `hostname`: a NixOS host's `hostname`
# binary lives in /run/current-system/sw/bin, which is on the PATH of an
# interactive login but NOT on the PATH a non-interactive ssh command session
# gets when the caller's environment is forwarded. Measured 2026-09-28: a run
# over ssh from a bb pane died here with `hostname: command not found`, which
# reads exactly like a broken host and is not one. `read` is a bash builtin, so
# it cannot be missing.
read -r hostname </proc/sys/kernel/hostname || fail "cannot read /proc/sys/kernel/hostname"
[ "$hostname" = "netcup" ] || fail "this script runs ON the netcup host (hostname is '$hostname'); from a workstation use scripts/self-deploy-host.sh"
printf '  hostname: %s\n' "$hostname"

step "the environment this step needs"
export NIX_SSHOPTS="-i $LOOPBACK_KEY -o IdentitiesOnly=yes"
export SECRETSPEC_REASON="${SECRETSPEC_REASON:-self-deploy on the host: deploying its own declaration over the loopback}"
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  [ -r "$CRED" ] || fail "OP_SERVICE_ACCOUNT_TOKEN is unset and $CRED is not readable — task 6.1's credential is missing; without it secretspec cannot resolve the profile"
  OP_SERVICE_ACCOUNT_TOKEN=$(cat "$CRED"); export OP_SERVICE_ACCOUNT_TOKEN
  printf '  OP_SERVICE_ACCOUNT_TOKEN exported from %s (value never printed)\n' "$CRED"
fi
printf '  NIX_SSHOPTS: -i %s -o IdentitiesOnly=yes\n' "$LOOPBACK_KEY"
printf '  SECRETSPEC_REASON is set\n'

step "the loopback identity authenticates root before the deploy depends on it"
# The known-hosts file must be WRITABLE BY THE CALLER: root's path
# (/root/.ssh/known_hosts) is what a root-run copy used, and as the operator it
# fails with "Failed to add the host to the list of known hosts (/root/.ssh/
# known_hosts)" — which the uid check below reads as a bad login. $HOME keeps
# the right file for both callers, and the key and target are unchanged.
out=$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=$HOME/.ssh/known_hosts -i "$LOOPBACK_KEY" root@localhost 'id -u' 2>&1) \
  || fail "ssh root@localhost with $LOOPBACK_KEY failed: $out"
[ "$out" = "0" ] || fail "loopback login reports uid '$out', not 0"
printf '  ssh root@localhost -> uid 0\n'

step "the host's own build of the declaration in the checkout"
before=$(readlink -f /run/current-system)
printf '  running now: %s\n' "$before"
SYS=$(devenv eval machines.netcup.build.nixos --no-tui 2>/dev/null \
      | grep -oE '/nix/store/[a-z0-9]+-nixos-system-netcup[^"]*' | head -1)
# NO python3 PARSES THE EVAL HERE, ON PURPOSE. The host's system packages are
# deliberately minimal — hosts/netcup/self-deploy.nix adds `git` and
# `_1password-cli` and nothing else — so the host has no python3 at all.
# Measured 2026-09-28: the first run of this file died here with
# `python3: command not found`, and the output read like a broken eval rather
# than a missing interpreter on the host. A grep for the store path is what the
# host's own toolset can do; keep it that way.
[ -n "$SYS" ] || fail "evaluating machines.netcup.build.nixos produced no store path — read the eval output above"
printf '  requested:   %s\n' "$SYS"

step "the deploy"
devenv machines deploy netcup -O $TARGET_OVERRIDE --no-tui --yes
rc=$?
printf '  deploy exit %s\n' "$rc"

step "what the target records afterwards"
status || printf '  NOTE machines status itself exited nonzero\n'
after=$(readlink -f /run/current-system)
printf '  running now: %s\n' "$after"
if [ "$after" = "$SYS" ]; then printf '  OK   the running system is the one this run requested\n'
else
  printf '  FAIL the running system is NOT the requested one\n'
  printf '       requested: %s\n       running:   %s\n' "$SYS" "$after"
  printf '       A deploy that failed its activation is rolled back to the previous\n'
  printf '       system, which is the safe outcome — read the status above for the\n'
  printf '       recorded failure and cause, then see docs/self-deploy-netcup.md §rollback.\n'
  [ "$rc" -eq 0 ] && rc=1
fi

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'SELF-DEPLOY COMPLETE: the host rebuilt itself from its own checkout.\n'
else printf 'SELF-DEPLOY FAILED (exit %s) — the previous system is still running unless the status above says otherwise.\n' "$rc"; fi
exit "$rc"