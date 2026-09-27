#!/bin/bash
# scripts/tailnet-preflight.sh — the gates for add-netcup-tailnet, in order.
#
# This is the runbook form of openspec/changes/archive/2026-09-27-add-netcup-tailnet/tasks.md
# groups 1-4. It writes nothing to the host and deploys nothing: it proves the
# vault, the manifest, the tailnet's name space and the built system are all in
# the state the change assumes, and stops.
#
# WHY A SCRIPT AND NOT AD-HOC COMMANDS: the change ends in a deploy whose whole
# point is that the host enrolls ITSELF, and the step after that — placing the
# auth key on a live host and starting the autoconnect unit — has no dry run
# and no rollback. A gate you retype from memory is not a gate.
#
# KNOWN DETAILS THIS SCRIPT CODES IN (measured 2026-09-27):
#   * `devenv machines <anything>` resolves the WHOLE secretspec profile, so a
#     missing vault session makes the MACHINE look broken. The vault is checked
#     directly here rather than inferred from that error.
#   * `machines.netcup.build.nixos` evaluates to a STORE PATH STRING, not an
#     attrset. The evaluated NixOS configuration is read out of the built
#     system's own /etc; `devenv eval machines.netcup.build.nixos.config...`
#     does not exist.
#   * `services.tailscale.authKeyFile` is `types.path`, which a plain absolute
#     STRING satisfies (verified: lib.types.path.check "/var/lib/..." is true),
#     so the value never enters /nix/store. A match from the store sweep below
#     means that property has been broken.
#   * `--hostname` and the ACL TAG are not readable from the closure: the name
#     comes from the flag, and the tag comes from the auth key. Only
#     `tailscale status --json` can report the tag.
#   * A secret value is never a grep ARGUMENT in this file — argv is readable
#     in `ps`. Patterns go in on stdin.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VAULT=${VAULT:-dev}
NODE=${NODE:-nc}
AUTHKEY_PATH=${AUTHKEY_PATH:-/var/lib/tailscale/authkey}

# The resolver devenv itself will use for `install.secrets`. Deliberately NOT
# `command -v secretspec`: measured 2026-09-27, the ambient
# ~/.cargo/bin/secretspec is 0.20.0 while devenv 2.4.0 bundles 0.21.0, and this
# manifest is written against the bundled one.
SECRETSPEC="$(readlink -f "$REPO/.devenv-toolchain")/bin/secretspec"

fail() { printf '\nGATE FAILED: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
# devenv renders its tables with ANSI escapes wrapped around every token, and
# NO_COLOR does not suppress them (measured 2026-09-27), so anything reading
# devenv's human output has to strip them first.
strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

# `require_reason = true` in secretspec.toml, plus devenv forwarding NO reason
# flag of its own (there is no `--reason` on the devenv CLI), means every
# `devenv machines …` call below needs this variable in the environment or it
# dies with "Accessing secrets requires a reason" (measured 2026-09-27). The
# scripts set it; anything invoking `devenv machines` by hand must too.
export SECRETSPEC_REASON="${SECRETSPEC_REASON:-tailnet preflight: verifying the machine, the manifest and the built system}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

step "1. the resolver is devenv's bundled secretspec"
[ -x "$SECRETSPEC" ] || fail "$SECRETSPEC missing — rebuild the toolchain with bin/devenv"
v=$("$SECRETSPEC" --version) || fail "cannot run $SECRETSPEC"
printf '  %s -> %s\n' "$SECRETSPEC" "$v"
[ "$v" = "secretspec 0.21.0" ] || fail "bundled resolver reports '$v'; this change was written against 0.21.0 — re-verify the manifest's provider syntax before deploying"

step "2. the Machine is declarable, and the vault session it needs is present"
if (cd "$REPO" && ./bin/devenv machines info --no-tui) >"$tmp/info" 2>&1; then
  strip_ansi <"$tmp/info" | grep -E '^\| netcup' | sed 's/^/  /'
  strip_ansi <"$tmp/info" | grep -qE '^\| netcup ' || fail "machines info ran but does not list netcup — the declaration changed shape"
else
  strip_ansi <"$tmp/info" | sed 's/^/  /'
  fail "devenv machines info — with a secretspec.toml in the tree this fails for TWO different reasons that look alike: the vault is unreachable (OP_SERVICE_ACCOUNT_TOKEN unset in this shell, or the service account cannot read the vault), or no reason was supplied (SECRETSPEC_REASON unset — require_reason = true in secretspec.toml, and devenv forwards no --reason of its own). Read the message above to tell them apart."
fi

step "3. the auth key item exists in the vault (title only; the value is never read)"
if ! op item list --vault "$VAULT" --format json >"$tmp/items" 2>"$tmp/op.err"; then
  sed 's/^/  /' "$tmp/op.err"; fail "op item list --vault $VAULT"
fi
python3 - "$tmp/items" "$VAULT" <<'PY' || fail "no TS_AUTH_KEY item in the $VAULT vault — create it (the value is minted in the Tailscale admin console, not by this repo)"
import json,sys
items=json.load(open(sys.argv[1]))
titles=[i.get("title","") for i in items]
print("  vault items:", ", ".join(sorted(titles)))
if "TS_AUTH_KEY" not in titles: sys.exit(1)
PY

step "4. the manifest resolves TS_AUTH_KEY"
if (cd "$REPO" && "$SECRETSPEC" check --no-prompt --json --reason "add-netcup-tailnet preflight") >"$tmp/check" 2>&1; then ok=1; else ok=0; fi
[ -s "$tmp/check" ] || fail "secretspec produced no report"
python3 - "$tmp/check" <<'PY' || fail "TS_AUTH_KEY did not resolve"
import json,sys
d=json.load(open(sys.argv[1]))
print("  provider:", d.get("provider"), " profile:", d.get("profile"))
for s in d.get("secrets",[]):
    print("  %-14s %s" % (s["name"], s["status"]))
    if s["name"]=="TS_AUTH_KEY" and s["status"]!="resolved": sys.exit(1)
PY
[ "$ok" = 1 ] || fail "secretspec check exited nonzero"

step "4b. the value is a real key, not an empty placeholder"
# `secretspec check --json` is value-free by design, so it cannot tell an empty
# field from a filled one: an item that exists with nothing in it still reports
# `resolved`. Measured reason this gate exists — the `dev` vault's service account
# is READ-ONLY, so the item is created by hand and can sit unfilled.
# This reads the value only to measure it, and discloses a prefix only when that
# prefix is the expected, non-secret vendor one.
keyinfo=$( (cd "$REPO" && "$SECRETSPEC" run --reason "add-netcup-tailnet preflight: measure the key" -- sh -c '
  v="${TS_AUTH_KEY:-}"
  [ -n "$v" ] || { echo EMPTY; exit 0; }
  p=$(printf %s "$v" | cut -c1-11)
  if [ "$p" = "tskey-auth-" ]; then echo "len=${#v} prefix=$p"; else echo "len=${#v} prefix=UNEXPECTED"; fi
') 2>/dev/null ) || fail "could not read TS_AUTH_KEY to measure it — does the item exist and does your token grant read access?"
case "$keyinfo" in
  EMPTY)
    fail "the TS_AUTH_KEY item exists but its value is EMPTY. Fill it in with a Tailscale auth key minted in the admin console (tag:server), then re-run." ;;
  *UNEXPECTED)
    printf '  %s\n' "$keyinfo"
    printf '  WARN the value does not start with the auth-key prefix. Tailscale distinguishes\n'
    printf '       key kinds: an API key or an OAuth client secret will be accepted here and\n'
    printf '       then rejected by the control server at enrollment, with a worse message.\n' ;;
  *)
    printf '  %s\n' "$keyinfo"
    printf '  OK   length and prefix describe a Tailscale auth key\n' ;;
esac

step "4c. the delivering path and the reading path are the same"
# The install-time writer (machines.netcup.install.secrets, in devenv.nix) and the
# runtime reader (services.tailscale.authKeyFile, in hosts/netcup/tailnet.nix) are
# declared in two different files that cannot see each other. Nothing but this
# check stops them drifting, and drift would mean a re-image enrolls from a file
# nothing reads.
if ! (cd "$REPO" && ./bin/devenv eval machines.netcup.install.secrets --no-tui 2>/dev/null) >"$tmp/secrets.json"; then
  fail "could not evaluate machines.netcup.install.secrets — is the install.secrets mapping present in devenv.nix?"
fi
python3 - "$tmp/secrets.json" "$AUTHKEY_PATH" <<'PY' || fail "the install-time delivery path does not match services.tailscale.authKeyFile"
import json,sys
d=json.load(open(sys.argv[1]))["machines.netcup.install.secrets"]
want=sys.argv[2]
print("  install.secrets:", json.dumps(d))
e=d.get(want)
if e is None: print("  no entry for %s" % want, file=sys.stderr); sys.exit(1)
if e.get("secret")!="TS_AUTH_KEY": print("  delivers %r, expected TS_AUTH_KEY" % e.get("secret"), file=sys.stderr); sys.exit(1)
if e.get("mode")!="0600": print("  mode is %r, expected 0600" % e.get("mode"), file=sys.stderr); sys.exit(1)
if e.get("owner")!="0:0": print("  owner is %r, expected 0:0" % e.get("owner"), file=sys.stderr); sys.exit(1)
PY
printf '  both sides name %s and secret TS_AUTH_KEY\n' "$AUTHKEY_PATH"

step "5. the name '$NODE' is free in the tailnet"
# THIS GATE IS PRE-ENROLLMENT BY CONSTRUCTION, and it is expected to FAIL from the
# moment this change has enrolled the host — the enrolled host IS the node named
# $NODE. Its job is the *fresh* enrollment case (a re-image, or a second host),
# where an old registration would push the new node to '$NODE-1'. Nothing this
# script can see distinguishes "the host this change enrolled" from "a stale or
# competing registration" — that needs host contact, which this script does not
# do — so it fails loudly and explains both cases instead of guessing.
tailscale status --json >"$tmp/ts.json" 2>/dev/null || fail "tailscale status --json — is this workstation logged in?"
python3 - "$tmp/ts.json" "$NODE" <<'PY' || fail "a node named '$NODE' exists. Before a FRESH enrollment that is fatal: Tailscale deduplicates node names, so the new node would come up as '$NODE-1'. If this change has already enrolled the host, this node IS that host and failing here is EXPECTED — re-check the enrolled state with scripts/tailnet-verify.sh instead, and delete this node only when a re-image makes a fresh enrollment necessary."
import json,sys
d=json.load(open(sys.argv[1])); node=sys.argv[2]
peers=d.get("Peer",{}) or {}
print("  tailnet nodes:", ", ".join(sorted(p.get("HostName","") for p in peers.values())))
hits=[p for p in peers.values() if p.get("HostName")==node or (p.get("DNSName") or "").startswith(node+".")]
if hits:
    h=hits[0]
    print("  COLLISION: %s online=%s tags=%s created=%s" % (h.get("DNSName"), h.get("Online"), h.get("Tags"), h.get("Created")), file=sys.stderr)
    sys.exit(1)
PY

step "6. the closure builds locally (nothing has written to the host yet)"
# `--no-tui` IS NOT COSMETIC HERE. In a bb terminal pane stdout is a TTY, so
# devenv renders a progress TUI that rewrites the pane continuously — measured
# 2026-09-27: one build emitted ~618 KB of spinner frames and buried every gate
# line around it. A non-TTY run (an agent's own tool call) prints terse lines
# instead, which is why this only bites in a pane.
(cd "$REPO" && ./bin/devenv build machines.netcup --no-tui >/dev/null) || fail "local build of machines.netcup"
printf '  build green\n'

step "7. the built system declares the enrollment, and carries no key value"
SYS=$( (cd "$REPO" && ./bin/devenv eval machines.netcup.build.nixos --no-tui 2>/dev/null) \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["machines.netcup.build.nixos"])' ) \
      || fail "could not evaluate machines.netcup.build.nixos"
printf '  system: %s\n' "$SYS"
unit="$SYS/etc/systemd/system/tailscaled-autoconnect.service"
[ -e "$unit" ] || fail "$unit is absent — services.tailscale.authKeyFile is unset, or hosts/netcup/tailnet.nix is not imported"
# THE SCRIPT BODY IS NOT IN THE UNIT. `systemd.services.<name>.script` is built
# into its OWN store path, and the unit carries only
# `ExecStart=…/unit-script-<name>-start/bin/<name>-start` (measured 2026-09-27:
# this gate failed on a configuration that was correct, because it grepped the
# unit for a string that lives one indirection away). Follow ExecStart.
script=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit" | head -1)
[ -n "$script" ] || fail "could not read ExecStart from $unit"
[ -f "$script" ] || fail "the unit's ExecStart script '$script' does not exist"
printf '  ExecStart script: %s\n' "$script"
grep -qF -- "cat $AUTHKEY_PATH" "$script" || fail "the autoconnect script does not read $AUTHKEY_PATH — services.tailscale.authKeyFile and the path machines.netcup.install.secrets writes have drifted apart"
grep -qF -- "--hostname=$NODE" "$script" || fail "the autoconnect script does not pin --hostname=$NODE (extraUpFlags missing?)"
grep -qF -- "WantedBy=multi-user.target" "$unit" || fail "the autoconnect unit is not wanted by multi-user.target, so nothing would enroll the host at boot"
# THE CONDITION IS LOAD-BEARING, NOT TIDINESS. With the key absent — the state
# this change deliberately passes through before enrollment — the generated unit
# LOOPS on the missing file and is killed by its start timeout. A FAILED new unit
# makes switch-to-configuration exit 4 and devenv roll the entire transaction
# back (measured 2026-09-27: `phase: "rolled-back"`, previousSystem restored), so
# without this condition the change CANNOT be deployed at all. With it, the
# absent-key case is a SKIP, which systemd reports as Result=success /
# is-failed=inactive / ConditionResult=no (measured on this host). See the long
# comment in hosts/netcup/tailnet.nix.
grep -qF -- "ConditionPathExists=$AUTHKEY_PATH" "$unit" || fail "the autoconnect unit does not carry ConditionPathExists=$AUTHKEY_PATH — with no key at that path the unit fails, switch-to-configuration exits 4, and the deploy is rolled back"
[ "$(cat "$SYS/etc/hostname")" = "netcup" ] || fail "etc/hostname is '$(cat "$SYS/etc/hostname")' — the node name must come from --hostname, leaving networking.hostName as netcup"
printf '  the unit reads the declared path and pins --hostname=%s; etc/hostname is still netcup\n' "$NODE"
sweep_rc=0
(cd "$REPO" && "$SECRETSPEC" run --reason "add-netcup-tailnet preflight: prove the store is clean" -- \
    sh -c 'if [ -z "${TS_AUTH_KEY:-}" ]; then exit 3; fi; printf %s "$TS_AUTH_KEY" | grep -rlF -f - "$1"' _ "$SYS") \
  >"$tmp/hits" 2>/dev/null || sweep_rc=$?
case "$sweep_rc" in
  0)
    printf '  the value appears in:\n'; sed 's/^/    /' "$tmp/hits"
    fail "the auth key value is inside the built system — the string-path property has been broken; diagnose before deploying" ;;
  1)
    printf '  no auth key value in the built system\n' ;;
  3)
    fail "TS_AUTH_KEY resolved to an EMPTY value — an empty pattern matches everything, so this gate would have been meaningless" ;;
  *)
    fail "the store sweep itself failed (exit $sweep_rc) — nothing was proven about the store" ;;
esac

step "8. the firewall facts are unchanged by this change"
if ! (cd "$REPO" && ./bin/devenv eval machines.netcup.deploy.facts --no-tui 2>/dev/null) >"$tmp/facts.json"; then
  fail "deploy.facts eval"
fi
python3 - "$tmp/facts.json" <<'PY' || fail "the firewall facts drifted — this change must not add a port"
import json,sys
f=json.load(open(sys.argv[1]))["machines.netcup.deploy.facts"]
fw,ssh=f["firewall"],f["ssh"]
print("  firewall enabled:", fw["enabled"], " tcp:", fw["allowedTCPPorts"], " ranges:", fw["allowedTCPPortRanges"])
print("  ssh ports:", ssh["ports"], " rootLogin:", ssh["rootLogin"], " hostname:", f["hostname"])
bad=[]
if not fw["enabled"]: bad.append("firewall disabled")
if fw["allowedTCPPorts"]!=[22]: bad.append("allowedTCPPorts != [22]")
if fw["allowedTCPPortRanges"]!=[]: bad.append("allowedTCPPortRanges not empty")
if ssh["rootLogin"]!="prohibit-password": bad.append("rootLogin changed — that is the hardening change's business, not this one")
if f["hostname"]!="netcup": bad.append("hostname != netcup")
if bad: print("  DRIFT: "+"; ".join(bad), file=sys.stderr); sys.exit(1)
PY
# services.tailscale.openFirewall keeps its default (false), so no UDP port is
# added and tailscale0 is NOT trusted by the firewall. SSH over the overlay
# works because port 22 is already open on every interface, not because the
# overlay is exempted. That is deliberate: exempting it here would pre-empt the
# hardening change's central decision.

printf '\nALL GATES GREEN.\n'
cat <<EOF
Nothing has touched the host yet. Next, and these all DO — so run each one in a
pane and watch it happen:

  1. ./scripts/bb-pane-run.sh --title "no-op deploy (prove the path)" -- \\
       ./bin/devenv machines deploy netcup --no-tui --yes
     Expect the plan, then activation. The host must come back with tailscaled
     RUNNING but the node NOT enrolled. --yes is not decoration: without it the
     plan is printed and the deploy waits at `Apply this fleet plan? [y/N]` for
     an answer that nothing in a pane will type. This is also the host's FIRST
     deploy: tasks.md group 5 exists to attribute any failure to that path
     rather than to tailscale.

  2. ./scripts/bb-pane-run.sh --title "tailnet: pre-enrollment state" -- \\
       ./scripts/tailnet-verify.sh
     Must report the clean pre-enrollment state: tailscaled up, and the
     autoconnect unit SKIPPED because there is no key (ConditionResult=no, NOT
     Result=failure — a failed unit aborts the switch and rolls the deploy back;
     that is why hosts/netcup/tailnet.nix pins ConditionPathExists on it).

  3. ./scripts/bb-pane-run.sh --title "enroll nc" -- ./scripts/tailnet-enroll.sh
     Copies the key to $AUTHKEY_PATH and waits for BackendState=Running.

  4. ./scripts/bb-pane-run.sh --title "tailnet: enrolled state" -- \\
       ./scripts/tailnet-verify.sh
     Must report the enrolled state.

  5. ./scripts/bb-pane-run.sh --title "tailnet: reboot rejoin" -- \\
       ./scripts/tailnet-reboot-check.sh
     Reboots the host and proves it rejoins the tailnet without the key again.
EOF
