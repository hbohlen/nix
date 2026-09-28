#!/usr/bin/env bash
# scripts/preflight.sh — the pre-install gates, in order, for the netcup Machine.
#
# This is the runbook form of docs/install-netcup.md steps 1-4. It touches
# nothing on the target: it reads the target's identity and disk, builds the
# closure locally, and stops.
#
# WHY A SCRIPT AND NOT AD-HOC COMMANDS: `devenv machines install` kexecs,
# partitions and formats WITHOUT PROMPTING and has no dry run, so every gate
# below has to be green before it runs — and a gate you retype from memory is
# not a gate. Exits nonzero on the first failure.
set -u

KEY=${KEY:-$HOME/.ssh/id_ed25519-op-dev}
EXPECTED_FP='SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ'
TARGET=${TARGET:-root@152.53.92.126}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# -F /dev/null because this workstation's ~/.ssh/config has historically
# carried a fragment whose ${XDG_RUNTIME_DIR} IdentityAgent line aborts every
# ssh invocation in a non-interactive environment (measured 2026-09-27; the
# stale Include is now disabled, but the gate must not depend on that).
SSH=(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$KEY")

fail() { printf '\nGATE FAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

step "1. the Machine is declared and enumerable"
(cd "$REPO" && ./bin/devenv machines info) || fail "devenv machines info"

step "2. the host identity is materialized, and is the expected key"
[ -r "$KEY" ] || fail "$KEY missing — materialize it (docs/install-netcup.md step 1; it needs an appended trailing newline)"
tmppub=$(mktemp); trap 'rm -f "$tmppub"' EXIT
ssh-keygen -y -f "$KEY" >"$tmppub" 2>/dev/null || fail "cannot derive a public key from $KEY (invalid format? missing trailing newline?)"
fp=$(ssh-keygen -lf "$tmppub" | awk '{print $2}')
printf '  %s -> %s\n' "$KEY" "$fp"
[ "$fp" = "$EXPECTED_FP" ] || fail "identity mismatch: derived $fp, expected $EXPECTED_FP"
printf '  matches the declared identity\n'

step "3. the closure builds locally (nothing has written to the target yet)"
(cd "$REPO" && ./bin/devenv build machines.netcup >/dev/null) || fail "local build of machines.netcup"
printf '  build green\n'

step "4. the target answers as root, with the intended key"
"${SSH[@]}" "$TARGET" 'hostname; grep PRETTY_NAME /etc/os-release' || fail "root ssh to $TARGET"
printf '  server-side authorized_keys:\n'
"${SSH[@]}" "$TARGET" 'ssh-keygen -lf <(cut -d" " -f1-2 /root/.ssh/authorized_keys)' | sed 's/^/    /' || fail "could not read authorized_keys"
printf '  key the server actually accepted, last time it logged one:\n'
"${SSH[@]}" "$TARGET" 'journalctl -u ssh -n 200 2>/dev/null | grep "Accepted publickey" | tail -1' | sed 's/^/    /'

step "5. the boot disk is the one the layout targets"
"${SSH[@]}" "$TARGET" 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS | grep -E "vda"' | sed 's/^/    /' || fail "could not read lsblk"

printf '\nALL GATES GREEN.\nNext (irreversible): ./bin/devenv machines install netcup --max-concurrent 1 --no-tui\n'
