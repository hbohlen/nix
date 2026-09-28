# Proposal: reconcile-netcup-install-spec

## Why

`openspec/specs/netcup-install/spec.md` requires **"The install path requires no
vault session and no tailnet"**, and its scenario *"Install runs with no provider
configured"* is conditioned on a workstation with **no `secretspec.toml` in the
repository** — a precondition this repository has not been able to meet since
`add-netcup-tailnet` put that file in the tree. That change's proposal listed
`netcup-machine` as its only modified capability and retired the identical
precondition there; the duplicate in `netcup-install` was missed. Install now
resolves a secret by design: every `devenv machines` invocation resolves the
whole profile, and `install.secrets."/var/lib/tailscale/authkey"` maps
`TS_AUTH_KEY`. A spec whose precondition the repository cannot satisfy turns a
correct install into an apparent violation — and this repository treats specs as
the contract, so the contract is what gets fixed.

**Milestone:** this is housekeeping on the second milestone (the host runs its
declared NixOS, with a tailnet and a self-deploy loop). It advances no new
capability; it makes the `netcup-install` capability describe the system that
exists, so the follow-ups in `docs/handoff-followups.md` §10 start from specs
that are true.

## What Changes

- **REMOVED** `netcup-install`'s requirement *"The install path requires no vault
  session and no tailnet"*. Its original text and both scenarios are kept in the
  delta with a **Reason** and a **Migration** pointer, so the retirement is
  visible in the canonical spec rather than looking like an oversight — the same
  convention `add-netcup-tailnet` used for `netcup-machine`'s retired scenario.
- **ADDED** a requirement stating what the install actually requires: a
  resolvable SecretSpec profile (it fails, naming the secret, when the vault does
  not resolve), and **no overlay membership on the target during the install
  run** — the true half of the old requirement, carried forward rather than
  discarded with the false one.
- **ADDED** this capability's missing `Purpose`, which still reads `TBD - created
  by archiving change add-netcup-bare-install`.
- Nothing else. No configuration, no script, no host, no vault.

**Non-goals:**

- Not deciding the access posture (tailnet-only SSH) or the R-A/R-B console
  recovery question — `docs/handoff-followups.md` §10 ledger #2 and #3.
- Not proving install-time secret delivery (ledger #4; needs a re-image). The
  delta states the declared contract and does not present it as measured.
- Not touching `netcup-install`'s *"Access works over the public address"*
  scenario, which is measured-true today and belongs to the posture change.
- Not filling `Purpose: TBD` in the other five capabilities (ledger #7).
- Not changing `devenv.nix`, `secretspec.toml`, `hosts/netcup/*`, or `scripts/*`.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `netcup-install`: the requirement *"The install path requires no vault session
  and no tailnet"* is removed because its precondition is unmeetable, and a new
  requirement states the install's real relationship to the vault (the profile
  must resolve) and to the overlay (the target needs no membership during the
  run; enrollment at first boot is `netcup-tailnet`'s requirement, not this
  capability's).

## Impact

- **Repository:** `openspec/specs/netcup-install/spec.md` — the requirement text
  changes through this change's delta at archive time, the `Purpose` header is
  edited directly (see design D5); plus this change's own artifacts.
- **Host / vault / toolchain:** none. No task in this change contacts the target,
  the Nix store, or 1Password, so no eval-or-check gate is required before any
  of them.
- **`~/projects/nixos`:** nothing is dropped or contradicted there. That
  implementation has no install-path spec this change touches; its ADRs and
  module split remain reference-only, and no decision is inherited by copying.
- **Consequences for later changes:** none are bound. The posture change will
  still have to modify `netcup-install`'s public-address evidence scenarios, and
  the install-time `TS_AUTH_KEY` delivery evidence stays open where §10 left it.
