#!/bin/bash
# scripts/tailnet-enroll.sh — the one step that changes the host's tailnet
# membership: put the auth key at the declared path, then let the machine's own
# unit use it.
#
# WHY THIS IS A SCRIPT AND NOT TWO COMMANDS IN tasks.md: it is the step with no
# dry run and no rollback, it moves a credential, and it is the one the operator
# most wants to watch. Two shell invocations plus a process substitution routed
# through a terminal pane is exactly the shape that gets mistyped, so the
# procedure lives here and the pane runs this.
#
# WHAT IT DOES NOT DO: it never prints the auth key, never writes it to a local
# file, and never passes it as an argument (argv is world-readable in `ps`, and a
# pane is a shared artifact — whatever reaches its scrollback is exposed to
# whoever is watching). The value goes from SecretSpec into the ssh channel on
# stdin and lands in a 0600 root-owned file on the host.
#
# IT DOES NOT DECIDE the key's life at rest. Removing the file after enrollment is
# design open question 2; pass --remove-key once that is settled. The default is
# to leave it, which is what keeps a future re-image self-enrolling.
#
# MEASURED / RELIED ON (2026-09-27):
#   * The pane does not inherit the agent shell's environment, so this script
#     bootstraps OP_SERVICE_ACCOUNT_TOKEN from ~/.config/op-sa-token itself.
#   * devenv bundles secretspec 0.21.0 while the ambient `secretspec` on PATH is
#     0.20.0, so the bundled resolver is called by path.
#   * `op inject` writes byte-exact (no trailing newline); the auth key is read by
#     `tailscale up --auth-key "$(cat FILE)"`, whose command substitution strips a
#     trailing newline anyway, so either form is safe here — unlike the SSH key.
set -u

TARGET=${TARGET:-152.53.92.126}
TARGET_USER=${TARGET_USER:-root}
KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
AUTHKEY_PATH=${AUTHKEY_PATH:-/var/lib/tailscale/authkey}
NODE=${NODE:-nc}
TAILNET_SUFFIX=${TAILNET_SUFFIX:-worm-hue.ts.net}
WAIT_SECONDS=${WAIT_SECONDS:-180}
REMOVE_KEY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-key) REMOVE_KEY=1; shift ;;
    --target) TARGET=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'tailnet-enroll.sh: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECRETSPEC="$(readlink -f "$REPO/.devenv-toolchain")/bin/secretspec"

fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

[ -x "$SECRETSPEC" ] || fail "$SECRETSPEC missing — rebuild with bin/devenv"
[ -r "$KEY" ] || fail "$KEY missing — materialize it (docs/install-netcup.md step 1; it needs an appended trailing newline)"

# The pane has no ambient credentials; take them from the 0600 file rather than
# demanding the operator pre-export them. Presence is stated, the value never is.
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$HOME/.config/op-sa-token" ]; then
  export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.config/op-sa-token")"
  printf '[enroll] OP_SERVICE_ACCOUNT_TOKEN exported from ~/.config/op-sa-token\n'
fi

SSH=(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$KEY")
rsh() { "${SSH[@]}" "$TARGET_USER@$TARGET" "$@"; }

step "1. the target answers, and this change has actually been deployed to it"
out=$(rsh 'hostname; command -v tailscale >/dev/null && tailscale version | head -1 || echo "tailscale: NOT INSTALLED"') \
  || fail "ssh to $TARGET_USER@$TARGET — is the key materialized and the host up?"
printf '%s\n' "$out" | sed 's/^/  /'
case "$out" in
  *"NOT INSTALLED"*) fail "tailscale is not on the host — deploy the change first (tasks 5–6). This script assumes the host is already running the configuration that names $AUTHKEY_PATH." ;;
esac

step "2. the host is not already enrolled"
state=$(rsh 'tailscale status --json --peers=false 2>/dev/null' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null || echo "?")
printf '  BackendState = %s\n' "$state"
case "$state" in
  Running) fail "the host is already enrolled — nothing to do (re-enrolling is a deliberate act: log out first if that is really intended)" ;;
  NeedsLogin|Stopped|"?") printf '  OK   not enrolled yet\n' ;;
  *) printf '  NOTE unexpected state %s — continuing, but read the journal afterwards\n' "$state" ;;
esac

step "3. the auth key resolves, and is not empty"
"$SECRETSPEC" run --reason "enrolling $NODE in the tailnet" -- \
  sh -c 'if [ -z "${TS_AUTH_KEY:-}" ]; then exit 3; fi; echo "[enroll] TS_AUTH_KEY resolved (value not shown)"' \
  || fail "TS_AUTH_KEY did not resolve to a non-empty value — run scripts/tailnet-preflight.sh"

step "4. place the key on the host, on stdin, at the declared path"
# The value travels: secretspec -> stdout -> ssh stdin -> remote `cat > file`.
# It is never an argument on either side, and never lands on local disk.
rsh "install -d -m 0755 /var/lib/tailscale && umask 077 && cat > '$AUTHKEY_PATH' && chmod 0600 '$AUTHKEY_PATH' && chown 0:0 '$AUTHKEY_PATH'" \
  < <("$SECRETSPEC" run --reason "enrolling $NODE in the tailnet" -- sh -c 'printf %s "$TS_AUTH_KEY"') \
  || fail "could not write $AUTHKEY_PATH on the host"
rsh "stat -c '  %n mode=%a owner=%U:%G size=%s' '$AUTHKEY_PATH'" || fail "could not stat the key file"
printf '  (size is checked, contents are not read)\n'

step "5. the machine enrolls itself, through its own unit"
rsh 'systemctl restart tailscaled-autoconnect.service; systemctl show -p Result --value tailscaled-autoconnect.service' >/dev/null 2>&1
printf '  waiting up to %ss for BackendState=Running...\n' "$WAIT_SECONDS"
started=$SECONDS
while :; do
  state=$(rsh 'tailscale status --json --peers=false 2>/dev/null' \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null || echo "?")
  [ "$state" = "Running" ] && { printf '  Running after %ss\n' "$(( SECONDS - started ))"; break; }
  [ $(( SECONDS - started )) -ge "$WAIT_SECONDS" ] && fail "still '$state' after ${WAIT_SECONDS}s — see: ssh $TARGET_USER@$TARGET 'journalctl -u tailscaled-autoconnect -n 60 --no-pager'"
  sleep 3
done

step "6. the unit reports success, and the journal explains itself"
printf '  Result=%s\n' "$(rsh 'systemctl show -p Result --value tailscaled-autoconnect.service')"
rsh 'journalctl -u tailscaled-autoconnect -n 12 --no-pager' | sed 's/^/  /'
printf '\n  Also check the journal contains no token material:\n'
if rsh 'journalctl -u tailscaled-autoconnect --no-pager' | grep -qiE 'tskey-|authkey-[A-Za-z0-9]'; then
  fail "a key-looking string is in the unit journal — the key reached the pane's scrollback; rotate it and inspect"
fi
printf '  OK   no key-shaped string in the journal\n'

step "7. the node, as the tailnet sees it"
printf '  self: %s\n' "$(rsh 'tailscale status --peers=false | head -1')"

if [ "$REMOVE_KEY" = 1 ]; then
  step "8. --remove-key: taking the key off the host"
  rsh "shred -u '$AUTHKEY_PATH' 2>/dev/null || rm -f '$AUTHKEY_PATH'" || fail "could not remove $AUTHKEY_PATH"
  rsh "ls -l '$AUTHKEY_PATH' 2>&1 || echo '  removed'"
  printf '  Recorded: the key is NOT at rest. A host whose node key is invalidated can no\n'
  printf '  longer re-enroll from its own configuration; only `install.secrets` can, and\n'
  printf '  only during an install.\n'
else
  printf '\nThe key is at rest at %s (mode 0600, root). That is what keeps a re-image\n' "$AUTHKEY_PATH"
  printf 'self-enrolling. Pass --remove-key if that trade is not wanted — see design\n'
  printf 'open question 2, and record the choice in docs/tailnet-netcup.md.\n'
fi

printf '\nENROLLED. Now read it back with scripts/tailnet-verify.sh\n'
