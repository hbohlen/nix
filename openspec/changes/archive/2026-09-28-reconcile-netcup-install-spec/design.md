# Design: reconcile-netcup-install-spec

## Context

`openspec/specs/netcup-install/spec.md` was promoted from
`2026-09-27-add-netcup-bare-install` and has not been revised since. The next
change, `add-netcup-tailnet`, put `secretspec.toml` in the tree, mapped
`TS_AUTH_KEY` through `machines.netcup.install.secrets`, and retired the
"evaluation succeeds with no vault" scenario in **`netcup-machine`** — its
proposal lists `netcup-machine` as the only modified capability
(`openspec/changes/archive/2026-09-27-add-netcup-tailnet/proposal.md`, the
"Modified Capabilities" block). The identical precondition in `netcup-install`
was never touched, so the canonical spec still requires an install path with no
vault session, no `secretspec.toml`, and no secret resolution.

Nothing about this change touches the host, the vault, the Nix store, or any
configuration file. It is a spec-text change, which is why it can be small.

**Measured facts this design rests on, with the command that produced them:**

| Fact | Command | Result |
|---|---|---|
| The stale requirement exists | `grep -n "requires no vault session" openspec/specs/netcup-install/spec.md` | line 52 |
| Its unmeetable precondition | `grep -n "no \`secretspec.toml\` in the repository" openspec/specs/netcup-install/spec.md` | line 63 |
| The Machine delivers a secret at install | `grep -n "install.secrets" devenv.nix` | line 81: `install.secrets."/var/lib/tailscale/authkey" = { secret = "TS_AUTH_KEY"; … }` |
| The secret is declared in the manifest | `grep -n "^TS_AUTH_KEY" secretspec.toml` | line 78, `providers = ["dev"]`, `ref.field = "credential"` |
| The tailnet change modified only `netcup-machine` | `grep -n "Modified Capabilities" -A6 openspec/changes/archive/2026-09-27-add-netcup-tailnet/proposal.md` | `netcup-machine` only |
| This capability has no Purpose | `grep -n "TBD - created by archiving" openspec/specs/netcup-install/spec.md` | line 4 |
| Toolchain the above runs against | `./bin/devenv --version`; `devenv.lock`; `/nix/store/axhrys71dyh0l7gynicv8mfy9y9mjc4i-devenv-wrapped-2.4.0/bin/secretspec --version` | `devenv 2.4.0+b904dcb (x86_64-linux)`; devenv `b904dcb51fe48c30db250038241507f60752f222`, nixpkgs `cachix/devenv-nixpkgs@c2f38fe7f9e04d9aadd354d380f2bd40531d9737`, disko `725ea35e410ad83be4931d1bff7e090eacaf3563`; `secretspec 0.21.0` |

*Caveat worth carrying:* `which secretspec` resolves to
`~/.cargo/bin/secretspec` (`0.20.0`), which is **not** what devenv uses. Cite
the bundled path above, or the version number in a task will silently be the
wrong binary's.

## Goals / Non-Goals

**Goals:**

- Make `netcup-install` describe the repository that exists: install requires a
  resolvable SecretSpec profile, and needs no overlay membership on the target
  during the run.
- Keep the retirement visible — original text, Reason, and Migration travel
  into the delta, so a reader of the canonical spec can see what was changed
  and why, as `netcup-machine`'s retired scenario already does.
- Keep the change to spec text: no configuration, no script, no host contact.

**Non-Goals:**

- Deciding the access posture (public SSH closed or not) or the R-A/R-B console
  recovery design — `docs/handoff-followups.md` §10, ledger #2 and #3.
- Proving `install.secrets` delivery (ledger #4). This delta asserts
  *resolution*, which is measured, and never asserts *delivery*, which is not.
- Editing any other capability, including the other five `Purpose: TBD` lines
  (ledger #7).
- Changing `netcup-install`'s public-address evidence scenarios, which the
  posture change owns.

## Decisions

**D1 — REMOVE + ADDED, not MODIFIED.**
The requirement's *title* is the false claim, so the choice of delta operation
is constrained by archive semantics, not style. Alternatives considered:

- *MODIFIED under the same name* — the delta format requires the header to
  match the canonical requirement exactly, so the title "requires no vault
  session" would survive inside content that says the opposite.
- *RENAMED + content change* — the schema's RENAMED operation is name-only;
  pairing it with an edit to the same requirement in one delta has ambiguous
  apply semantics and this change exists to *reduce* ambiguity.
- **Chosen: REMOVE with Reason/Migration + ADDED with the corrected thesis.**
  The requirement is inverted, not refined, and each operation stays in the
  form the schema defines unambiguously.

**D2 — Carry the true half forward instead of deleting it with the false half.**
The old requirement held two claims: "no vault session" (false now) and "the
target joins no overlay during the install" (true, and load-bearing — a freshly
imaged target has no tailnet membership, which is exactly why re-image works at
all). Dropping the whole requirement would silently lose the second claim.
Alternative rejected: let `netcup-tailnet` own it — that capability starts at
first boot, so no overlay membership *during the run* would have no owner.

**D3 — Reference delivery; do not re-specify it.**
`netcup-tailnet`'s *The host enrolls from its own configuration* already owns
the `install.secrets` → `authKeyFile` path identity, mode `0600`, and
`ConditionPathExists` behaviour. This delta says the declared secrets *resolve*
before the irreversible step and points at enrollment as another capability's
concern. Alternative rejected: spell out the delivery mechanics here too —
two capabilities owning one behavior is precisely the drift this change is
fixing.

**D4 — Leave the public-address scenarios untouched.**
*"Access works over the public address"* is measured-true today. Rewriting it
here would fold the access-posture decision (ledger #3) into a truth-up and
force that decision without stating it.

**D5 — Write `Purpose` by editing the canonical file directly.**
The delta format has no Purpose operation, and the canonical file's own line
says "Update Purpose after archive." Evidence that archiving merges rather than
rebuilds: `add-netcup-tailnet`'s delta contained no Purpose section, yet the
promoted file still carries "created by archiving change add-netcup-bare-install".
Alternative rejected: defer it to ledger #7 with the other five — acceptable
fallback if `openspec validate --strict` objects to a direct header edit.

## Risks / Trade-offs

- **[R1] Archive semantics for REMOVE+ADDED differ from expectation** →
  mitigate by running `openspec validate` (and `--strict`) before any archive,
  reading the delta back, and keeping the canonical file in git so an archive
  that surprises us is a one-command revert. No host state exists to unwind.
- **[R2] The scenario *"The profile is resolved before the irreversible step"*
  may overstate timing** (see assumption A1) → the wording ties the failure to
  "before partitioning"; if a measurement ever shows lazy resolution, reword the
  scenario to "before first boot" rather than weakening the requirement.
- **[R3] `Purpose` lands in the canonical spec before archive** → if the change
  is abandoned, the file has a Purpose over stale requirements. Trivially
  reverted; no behavior anywhere depends on it.
- **[R4] A reader mistakes this change for approval of the hardening /
  posture follow-ups** → the proposal's Non-Goals name them explicitly and point
  at §10's ledger.
- **[R5] The `secretspec` on `PATH` is 0.20.0, not devenv's 0.21.0** → any task
  that reports a version must name the bundled binary path (design Context).

## Assumptions about the live host and the vault

- **A1 — profile resolution happens on every `machines` invocation, including
  `install`, and before partitioning.** Basis: the measured constraint recorded
  in `openspec/config.yaml` ("every `devenv machines` invocation, read-only ones
  included, resolves the whole secretspec profile") and handoff §1. *If wrong:*
  install could discover a missing credential after the irreversible step, and
  the new scenario's timing claim would be false — the requirement would need
  rewording to promise resolution "before first boot" instead. Settling it
  properly needs a run against a disposable target, which does not exist, so it
  is recorded as an assumption rather than measured here.
- **A2 — `install.secrets` writes `/var/lib/tailscale/authkey` after
  `nixos-install` and before the first boot.** Basis: declared in `devenv.nix`
  and specified by `netcup-tailnet`; **unverified — needs a re-image**
  (handoff §10 ledger #4). *If wrong:* `netcup-tailnet`'s requirement fails, not
  this one, because D3 keeps delivery out of this delta — which is the reason
  for D3.
- **A3 — nothing in this change depends on the host or the vault being
  reachable.** *If wrong:* a task unexpectedly needs either, it must be
  re-scoped, since the change is designed to complete offline.

## Migration Plan

Not applicable in the deployment sense: no system state changes. The canonical
spec changes when the change is archived (requirement text via the delta,
`Purpose` via the direct edit), and rollback for either is `git revert`. Order
of operations: artifacts → `openspec validate` → direct `Purpose` edit →
archive → confirm `openspec/specs/netcup-install/spec.md` reads true end to end.

## Open Questions

None blocking this change. Deliberately left open and tracked in
`docs/handoff-followups.md` §10: the access posture (#3), the install-time
delivery evidence (#4), R-A vs R-B (#2), and the other five `Purpose: TBD`
headers (#7).
