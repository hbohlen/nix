# Proposal: adopt-machines-check-and-plan

## Why

The self-deploy loop's safety rests on gates the repository hand-rolls, and its
one act that touches the live host is a single irreversible command. Step 9 of
`scripts/self-deploy-preflight.sh` evaluates `machines.netcup.deploy.facts` and
asserts the firewall and root-login posture by hand, and step 8 of
`scripts/tailnet-preflight.sh` duplicates that assertion. The deploy itself is
one shot — `devenv machines deploy netcup … --yes` in
`scripts/self-deploy-run.sh` — which builds, copies and activates with no
reviewable step between the declaration and activation. devenv 2.4 ships both
missing pieces: `machines check <name>` compares declared SSH access with facts
read from the target without building or deploying and refuses a change that
would disable SSH or root login, and `machines plan` → `machines apply` records
a deployable plan for review before anything activates.

This change advances the self-deploy milestone — the host rebuilds itself from
its own checkout over its own loopback and stays reachable — by making its
access gate a maintained, first-class check and its deploy an inspect-then-apply
step. It matters now because the host is live and no longer disposable, and the
failure this repository most fears is a deploy that quietly closes the control
channel it deploys over.

## What Changes

- Adopt `devenv machines check netcup` as the access-change gate in the
  workstation-side preflight. It compares the declared SSH access with facts
  read from the target without building or deploying; a configuration that would
  disable SSH or root login fails the check and stops the loop (SSH-port and
  admin-key changes are warnings), and `check --json` is the structured form.
  This replaces the hand-written firewall-facts assertion in
  `scripts/self-deploy-preflight.sh` step 9 and the duplicate in
  `scripts/tailnet-preflight.sh` step 8.
- **BREAKING**: replace the one-shot host-side deploy in
  `scripts/self-deploy-run.sh` — `devenv machines deploy netcup
  -O machines.netcup.target.host:string root@localhost --no-tui --yes` — with
  `devenv machines plan netcup`, operator review, then `devenv machines apply
  plan-…`. Saved plans live under `.devenv/machine-plans/<id>/`, retain their
  outputs, and `apply` rejects a stale plan. The documented one-shot deploy path,
  and the `netcup-self-deploy` requirement that names it, are replaced; the
  procedure of record changes with them.
- Keep the loop's entry and verdict in `scripts/self-deploy-host.sh` and
  `scripts/self-deploy-run.sh`, adapted to the plan/apply shape and still
  reading `machines status` back afterwards.
- Record the tool's limits where the gate is run: `check` cannot verify external
  firewalls, dynamic keys, or that the operator possesses a working key. Those
  stay custom preflight assertions; only the declared-access facts move to
  `check`.
- State that a plan is a trusted deployment input — it selects executable store
  paths — and that a changed target or generation makes it stale. The default
  human fallback remains `machines status` / `machines rollback`.

### Non-goals

- Not closing root login, not changing the firewall or sshd posture, and not
  narrowing the addresses from which root may log in; that is the hardening
  change (`docs/handoff-followups.md` §3/§10) and must keep loopback root
  reachable. `machines install` and `machines deploy` still require root SSH and
  this change does not relax that.
- Not re-imaging the host, and not changing the disk layout or the install flow.
- Not adopting the other devenv opportunities in
  `docs/devenv-feature-opportunities.md`: this change is items 6 and 7 only — not
  `install.copyHostKeys` (item 8), not the `tasks.*` refactor (item 4), not
  profiles, tests, or the `require_version` pin.
- Not adding or removing a secret, and not changing the single-Machine
  declaration or the per-invocation loopback target override.
- Not changing `netcup-machine`: its root-key SSH requirement is preserved, not
  relaxed.

### Not inherited from `~/projects/nixos`

The previous implementation's ADR-0006 ("Declare the NixOS host as a devenv
Machine beside the flake host") proposed Machines and then **rejected adopting
it**, recording `devenv machines check netcup` as unusable — exit 255 from a
broken ambient `~/.ssh/config` and exit 1 because the target ran Debian with no
`/run/current-system`. This change contradicts that rejection and that reading:
it adopts `check` and `plan`/`apply` against a different host and access path —
`~/nix`'s netcup now runs the declared NixOS and is reached over `-F /dev/null`
SSH options on the host's own loopback — and on an install/deploy path that
already works. ADR-0006's finding that root SSH blocks Machines is settled
differently here: the declaration keeps `PermitRootLogin = "prohibit-password"`
plus a root key, so `check` has a root path to compare rather than a posture that
forbids one. The prior implementation's deploy was deploy-rs
(`deploy.nodes.netcup`), not Machines; that mechanism is **dropped** and not
inherited. These decisions are re-decided for this host, and where they diverge
the divergence is stated rather than copied.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `netcup-self-deploy`: the loop's deploy step changes from a one-shot
  `devenv machines deploy` to `plan` → review → `apply`, and its pre-deploy
  access gate becomes `devenv machines check` — which refuses a configuration
  that would disable SSH or root login — rather than a hand-written
  firewall-facts assertion. This changes the "A deploy run on the host rebuilds
  and activates the host's own system" requirement and the access/loopback-safety
  requirement beside it.

`netcup-machine` is not modified: root-key SSH on the target's public address is
required and preserved exactly as that capability already states, and the check
gate enforces that posture rather than changing it. No other existing capability
has a spec-level requirement change.

## Impact

- `scripts/self-deploy-preflight.sh` — step 9's hand-written firewall-facts
  assertion is replaced by `machines check`; the gate order and its remaining
  custom checks (declared target and identity path, private-key sweep, loop
  record) are adjusted. Unlike the local eval it replaces, `check` reads facts
  **from the live target** (read-only), so the preflight's "touches nothing"
  property narrows to "writes nothing".
- `scripts/tailnet-preflight.sh` — step 8's duplicate firewall-facts assertion is
  replaced by the same `check`.
- `scripts/self-deploy-run.sh`, `scripts/self-deploy-host.sh` — the host-side
  loop runs `plan` → review → `apply`, retains plans under
  `.devenv/machine-plans/<id>/`, and reads `machines status` back as before.
- `docs/self-deploy-netcup.md` — the procedure of record's deploy step and its
  evidence commands change.
- `openspec/specs/netcup-self-deploy/spec.md` — delta spec required (specs
  phase).
- No `devenv.nix` declaration change is anticipated; whether `check` needs
  declared facts this repository does not already carry is a design decision,
  not a proposal one.
- Operational: the loop gains a reviewable artifact between declaration and
  activation, and it can no longer proceed over a configuration that would close
  SSH or root login.

Cite: <https://devenv.sh/machines/> ·
<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>
