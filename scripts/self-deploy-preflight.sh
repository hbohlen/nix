#!/usr/bin/env bash
# scripts/self-deploy-preflight.sh — the workstation-side gates for
# add-netcup-self-deploy, in order.
#
# This is the runbook form of openspec/changes/add-netcup-self-deploy/tasks.md
# groups 1-5. It touches NOTHING on the host and deploys nothing. It proves the
# declaration is one declaration, that the built system carries the preconditions
# the host-side loop needs, that both of root's identities are public-only, and
# that the firewall facts are unchanged — then stops.
#
# WHY A SCRIPT AND NOT AD-HOC COMMANDS: the deploy this change enables runs on
# the host, against the host, and holds the host's own control channel open while
# it activates. A gate retyped from memory is not a gate, and the failure it
# would have caught is a host that cannot rebuild itself.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * `require_reason = true` in secretspec.toml, and devenv forwards no reason
#     flag of its own, so EVERY `devenv machines …` and `devenv eval …` call below
#     needs SECRETSPEC_REASON in the environment or it dies with "Accessing
#     secrets requires a reason".
#   * With a secretspec.toml in the tree, a missing vault session makes the
#     MACHINE look broken: `machines info` exits 1 with a 1Password provider
#     error, not with a machine error. Read the message, do not infer.
#   * `devenv eval <attr>` prints its progress lines on stderr and one JSON
#     object on stdout, keyed by the attribute asked for.
#   * `machines.netcup.build.nixos` evaluates to a STORE PATH STRING. The
#     evaluated configuration is read out of the built system's own /etc;
#     `eval machines.netcup.build.nixos.config…` does not exist.
#   * `--no-tui` is not cosmetic: in a bb pane stdout is a TTY and devenv renders
#     a progress TUI that rewrites the pane continuously (measured: ~618 KB of
#     spinner frames for one build).
#   * A secret value is never a grep ARGUMENT in this file — argv is readable in
#     `ps`. Patterns go in on stdin.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_HOST=${TARGET_HOST:-root@152.53.92.126}
# The one declared client-identity path. It is the vault key's path on a
# workstation and the loopback key's path on the host (design D4), which is why
# it is read here as a LITERAL and compared against the declaration rather than
# resolved.
SSHOPT_PATH=${SSHOPT_PATH:-/home/hbohlen/.ssh/id_ed25519-op-dev}
LOOPBACK_FP=${LOOPBACK_FP:-SHA256:WgXJgoyQQ9pTLPVcWL31pnzNFPo/qR0zSPXmj6PEK8I}
OPERATOR_FP=${OPERATOR_FP:-SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ}

# The resolver devenv itself will use. Deliberately NOT `command -v secretspec`:
# measured 2026-09-27, the ambient ~/.cargo/bin/secretspec is 0.20.0 while devenv
# 2.4.0 bundles 0.21.0, and this manifest is written against the bundled one.
SECRETSPEC="$(readlink -f "$REPO/.devenv-toolchain")/bin/secretspec"

fail() { printf '\nGATE FAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
# devenv wraps its tables in ANSI escapes and NO_COLOR does not suppress them
# (measured 2026-09-27), so anything reading devenv's human output strips first.
strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

export SECRETSPEC_REASON="${SECRETSPEC_REASON:-self-deploy preflight: proving the declaration the host will rebuild from}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

devenv() { (cd "$REPO" && ./bin/devenv "$@" --no-tui); }
evalattr() { # evalattr <attribute> -> JSON on stdout, progress on stderr
  (cd "$REPO" && ./bin/devenv eval "$1" --no-tui 2>/dev/null) \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[list(d)[0]]; print(d if isinstance(d,str) else json.dumps(d))'
}

step "1. the resolver is devenv's bundled secretspec"
[ -x "$SECRETSPEC" ] || fail "$SECRETSPEC missing — the pinned toolchain is not materialized; run ./bin/devenv once on this workstation"
v=$("$SECRETSPEC" --version) || fail "cannot run $SECRETSPEC"
printf '  %s -> %s\n' "$SECRETSPEC" "$v"
[ "$v" = "secretspec 0.21.0" ] || fail "bundled resolver reports '$v'; re-verify the manifest's provider syntax before trusting this preflight"

step "2. the Machine is declarable, and there is exactly ONE"
if devenv machines info >"$tmp/info" 2>&1; then
  strip_ansi <"$tmp/info" | grep -E '^\| netcup' | sed 's/^/  /'
  n=$(strip_ansi <"$tmp/info" | grep -cE '^\| [a-z0-9]')
  [ "$n" = 1 ] || fail "machines info lists $n machines — the target override must redirect an INVOCATION, not a second declaration (design D2)"
else
  strip_ansi <"$tmp/info" | sed 's/^/  /'
  fail "devenv machines info — with a secretspec.toml in the tree this fails for TWO reasons that look alike: the vault is unreachable (OP_SERVICE_ACCOUNT_TOKEN unset here, or the service account cannot read the vault), or no reason was supplied (SECRETSPEC_REASON). Read the message above to tell them apart."
fi

step "3. the declared target is the public address, and the declared identity path is the one path"
evalattr machines.netcup.target >"$tmp/target" || fail "eval machines.netcup.target"
python3 - "$tmp/target" "$TARGET_HOST" "$SSHOPT_PATH" <<'PY' || fail "the target declaration drifted"
import json,sys
t=json.load(open(sys.argv[1]))
want_host,want_path=sys.argv[2],sys.argv[3]
host,(opts)=t["host"],t["sshOpts"]
print("  host:",host,"sshOpts:",opts)
bad=[]
if host!=want_host: bad.append("host is %r, expected %r"%(host,want_host))
if want_path not in opts: bad.append("sshOpts does not name %r — IdentitiesOnly=yes then hides every key"%want_path)
if "-i" not in opts: bad.append("sshOpts has no -i")
if bad: print("  DRIFT: "+"; ".join(bad), file=sys.stderr); sys.exit(1)
PY

step "4. the closure builds, and the built system is the one the host rebuilds"
# The BUILD comes first, and the eval after it: `eval machines.netcup.build.nixos`
# prints a store path whether or not anything built it, so a gate that only
# evaluates proves nothing about the closure (measured 2026-09-28 — the eval of
# the loop-record change printed 18ml7pjxf4s6…, which no one had built).
devenv build machines.netcup >/dev/null || fail "local build of machines.netcup"
SYS=$(evalattr machines.netcup.build.nixos) || fail "eval machines.netcup.build.nixos"
printf '  system: %s\n' "$SYS"
# 7.2/7.3 measured this exact path on the host (zzh5rm53…) for revision 6ab24452,
# so a NAME comparison is meaningful only for the revision being checked. The
# name is printed rather than asserted: the host's own build is verified by
# scripts/self-deploy-verify.sh, on the host, where it belongs.
[ -e "$SYS" ] || fail "$SYS does not exist — the eval printed a path nobody built"

step "5. the built system declares the nix features a non-interactive build needs"
grep -h 'experimental-features' "$SYS/etc/nix/nix.conf" >"$tmp/features" 2>/dev/null \
  || fail "$SYS/etc/nix/nix.conf has no experimental-features line — hosts/netcup/self-deploy.nix is not imported, or the setting was removed"
sed 's/^/  /' "$tmp/features"
grep -qE 'nix-command' "$tmp/features" && grep -qE 'flakes' "$tmp/features" \
  || fail "the declared settings omit nix-command or flakes; the host cannot run devenv at all without both"

step "6. the built system carries git and the 1Password CLI the vault provider wraps"
for p in git op; do
  if [ -x "$SYS/sw/bin/$p" ]; then printf '  %s -> %s\n' "$p" "$SYS/sw/bin/$p"
  else fail "$SYS/sw/bin/$p is absent — the host either cannot hold a checkout (git) or cannot resolve the profile (op); see risk R10"; fi
done

step "7. the built system remounts its store read-write at boot"
unit="$SYS/etc/systemd/system/nix-store-remount-rw.service"
[ -e "$unit" ] || fail "$unit is absent — without it the host can only RECEIVE store copies, never build (risk R11)"
grep -qF 'mount -o remount,rw /nix/store' "$unit" || fail "$unit does not remount /nix/store read-write"
grep -qF 'Before=nix-daemon.service' "$unit" || fail "$unit is not ordered before nix-daemon.service"
grep -qF 'WantedBy=multi-user.target' "$unit" || fail "$unit is not wanted by multi-user.target, so it would never run"
printf '  %s remounts /nix/store rw before nix-daemon\n' "$(basename "$unit")"

step "8. both of root's identities are PUBLIC halves, and no private half is in the tree or the store"
grep -qF 'netcup-loopback' "$REPO/hosts/netcup/default.nix" \
  || fail "hosts/netcup/default.nix does not declare the loopback public half — root would not accept the host's own key"
fp=$(sed -n 's/.*\(ssh-ed25519 [A-Za-z0-9+/=]*\) netcup-loopback.*/\1/p' "$REPO/hosts/netcup/default.nix" \
     | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
printf '  declared loopback key -> %s\n' "${fp:-UNREADABLE}"
[ "$fp" = "$LOOPBACK_FP" ] || fail "the declared loopback key is not the measured one ($LOOPBACK_FP) — a key was swapped and the host's private half no longer matches"
# The operator key is a declared literal too; a mismatch here means the host no
# longer authorizes the identity the workstation deploys with.
grep -qF 'netcup-devenv' "$REPO/hosts/netcup/default.nix" || fail "the operator key is no longer declared in hosts/netcup/default.nix"
# The pattern is assembled from two pieces so that THIS FILE does not match
# itself. A gate that reports the gate is a gate the operator learns to ignore.
PRIV="BEGIN OPENSSH PRIV""ATE KEY"
if grep -rlF "$PRIV" "$REPO" --exclude-dir=.git --exclude-dir=.jj --exclude-dir=.devenv --exclude-dir=.machines >"$tmp/keys" 2>/dev/null; then
  sed 's/^/    /' "$tmp/keys"; fail "private key material is inside the repository tree"
fi
if grep -rlF "$PRIV" "$SYS" >"$tmp/keys2" 2>/dev/null; then
  sed 's/^/    /' "$tmp/keys2"; fail "private key material is inside the built system (that store path is world-readable)"
fi
printf '  no private key material in the tree or in %s\n' "$SYS"

step "9. the firewall facts are unchanged by this change"
devenv eval machines.netcup.deploy.facts >"$tmp/facts" 2>/dev/null || fail "eval machines.netcup.deploy.facts"
python3 - "$tmp/facts" <<'PY' || fail "the firewall facts drifted — this change must not open or close a port"
import json,sys
f=json.load(open(sys.argv[1]))
f=f[list(f)[0]] if "machines.netcup.deploy.facts" not in f else f["machines.netcup.deploy.facts"]
fw,ssh=f["firewall"],f["ssh"]
print("  firewall enabled:",fw["enabled"]," tcp:",fw["allowedTCPPorts"]," ranges:",fw["allowedTCPPortRanges"])
print("  ssh ports:",ssh["ports"]," rootLogin:",ssh["rootLogin"]," hostname:",f["hostname"])
bad=[]
if not fw["enabled"]: bad.append("firewall disabled")
if fw["allowedTCPPorts"]!=[22]: bad.append("allowedTCPPorts != [22]")
if fw["allowedTCPPortRanges"]!=[]: bad.append("allowedTCPPortRanges not empty")
if ssh["rootLogin"]!="prohibit-password": bad.append("rootLogin changed — that is the hardening change's business, not this one")
if f["hostname"]!="netcup": bad.append("hostname != netcup")
if bad: print("  DRIFT: "+"; ".join(bad), file=sys.stderr); sys.exit(1)
PY

step "10. the loop's declared parameters agree with the scripts that read them"
# The branch is the one fact that exists both in the declaration (which the host
# carries) and in the scripts (which the workstation runs), so it is the one that
# can silently disagree. The scripts' default is read out of the drift check,
# because that is the file whose verdict a deploy depends on.
LOOPJSON="$SYS/etc/netcup-self-deploy/loop.json"
[ -f "$LOOPJSON" ] || fail "$LOOPJSON is absent from the built system — hosts/netcup/self-deploy.nix no longer declares the host's record of the loop"
script_branch=$(sed -n 's/^BRANCH=${BRANCH:-\([^}]*\)}.*/\1/p' "$REPO/scripts/self-deploy-drift.sh" | head -1)
[ -n "$script_branch" ] || fail "could not read BRANCH's default out of scripts/self-deploy-drift.sh — this gate cannot compare anything"
python3 - "$LOOPJSON" "$script_branch" <<'PY' || fail "the host's record of the loop and the scripts disagree"
import json,sys
path,script_branch=sys.argv[1],sys.argv[2]
d=json.load(open(path))
print("  %s"%json.dumps(d,sort_keys=True))
want={"repository","branch","checkout","targetOverride","loopbackKey","authored"}
extra=set(d)-want
if extra: print("  FAIL unexpected keys: %s — a field added here is a field nothing checks"%" ".join(sorted(extra))); sys.exit(1)
missing=want-set(d)
if missing: print("  FAIL missing keys: %s"%" ".join(sorted(missing))); sys.exit(1)
if d["branch"]!=script_branch:
    print("  FAIL the host declares branch %r; the scripts check %r"%(d["branch"],script_branch)); sys.exit(1)
if d["targetOverride"]!="machines.netcup.target.host:string root@localhost":
    print("  FAIL targetOverride is not the loopback override: %r"%d["targetOverride"]); sys.exit(1)
print("  OK   branch %r is the one the drift check expects, and the override is the loopback"%(script_branch,))
PY

printf '\nALL GATES GREEN.\n'
cat <<EOF
Nothing has touched the host. The next steps DO touch it, so each one is run in
a pane and watched (netcup-operations):

  1. ./scripts/bb-pane-run.sh --title "self-deploy drift" -- ./scripts/self-deploy-drift.sh
     The host's checkout must be the pushed revision with no uncommitted
     difference. Bring it there with, on the host:
       cd /home/hbohlen/nix && git pull --ff-only

  2. ./scripts/bb-pane-run.sh --title "host preconditions" -- ./scripts/self-deploy-verify.sh
     Read-only evidence that the declaration landed on the host: the nix
     features, git, op, the writable store, the loopback identity at the
     declared path, and a loopback nix store over ssh.

  3. ./scripts/bb-pane-run.sh --title "self-deploy from the host" -- ./scripts/self-deploy-host.sh
     The deploy itself, run ON the host against root@localhost. Expect the plan,
     then activation, then a machines status that says succeeded rather than
     rolled back.
EOF