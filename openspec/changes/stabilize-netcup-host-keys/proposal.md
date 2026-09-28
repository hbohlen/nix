# Proposal: stabilize-netcup-host-keys

## Why

The installed host's SSH host key has no declared provenance. The install path
leaves the installed system to generate `/etc/ssh/ssh_host_*` on first boot, and
its survival across the install reboot is only *re-verified by hand*:
`scripts/reboot-check.sh` and `scripts/tailnet-reboot-check.sh` record the
fingerprint before and after the reboot and report a change as a note to
investigate, never as a violation of a declared property. That gap has a
concrete cost: an install that transmits local files or secret values needs a
pre-pinned host key, and without one fails with the documented trap
"Host key verification failed".

This change advances the install-procedure milestone — a host that boots and is
reachable over SSH — by making host-key continuity a declared install-time
property instead of an assumption the operator keeps re-checking.

## What Changes

- Set `machines.netcup.install.copyHostKeys = true` (boolean, default `false`)
  in `devenv.nix`, so the installer's `/etc/ssh/ssh_host_*` are copied into the
  installed system before reboot. The installed host then presents the host key
  the installer environment already had, rather than generating a fresh one at
  first boot.
- Record host-key provenance as install-time evidence, and state in the
  `netcup-install` spec that a successful install leaves a host key that
  survives the install reboot as a declared property — not one merely observed
  by a verification script after the fact.
- Align `docs/install-netcup.md` with the new declaration: its install and
  post-install evidence sections describe the copied host key and how it is
  confirmed.
- **BREAKING**: this **changes the deployed host keys**. A freshly installed
  system presently generates its own `/etc/ssh/ssh_host_*`; with
  `copyHostKeys` it inherits the live installer's. Host-key provenance moves
  from "first-boot keygen" to "install-time copy", which is a deliberate,
  security-relevant decision: the host's SSH server identity is now derived
  from the ephemeral installer environment. Any external party that pinned the
  old post-install key (or expects a distinct key per boot cycle) must be told.
  This setting is install-time only, so it does not alter the already-installed
  host unless the host is re-imaged.
- Keep `scripts/reboot-check.sh` and `scripts/tailnet-reboot-check.sh` as the
  evidence that the declared property holds; their fingerprint comparison
  becomes a check of a declared invariant rather than the only record of it.

### Non-goals

- Not re-imaging or otherwise touching the currently running host; this change
  affects the next install only.
- Not adding an in-repo host-key pin (no committed `known_hosts`), and not
  changing the operator identity, which remains the 1Password `dev` vault
  `SSH Key`.
- Not changing root-access posture or any hardening, tailnet, secret-provider,
  or task/tooling concern — each stays a separate change.
- Not adopting `install.extraFiles` or `install.encryptionKeys`, and not
  removing the reboot-check scripts.

### Not inherited from `~/projects/nixos`

The previous implementation pinned the netcup host key in a committed
`deploy/known_hosts.netcup` with `StrictHostKeyChecking yes`, consumed by
`deploy/netcup-install.sh` and `deploy/ssh-config.netcup`. This repository does
not inherit that decision and does not add a replacement pin; it makes
host-key continuity an install-time property instead. The prior pin is
REFERENCE material only.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `netcup-install`: the install now copies the live installer's SSH host keys
  into the installed system before reboot, and a successful install must record
  the resulting host key as a declared, surviving property. This changes the
  "A successful install produces recorded evidence" requirement and the
  install-time behavior the requirement covers.

`netcup-machine` is not modified: its requirements concern the operator's
authorized keys and unattended UEFI boot, neither of which this change alters.
No other existing capability has a spec-level requirement change.

## Impact

- `devenv.nix` — the `machines.netcup` declaration gains
  `install.copyHostKeys = true`.
- `openspec/specs/netcup-install/spec.md` — delta spec required (specs phase).
- `docs/install-netcup.md` — install and post-install evidence sections; also
  removes the now-stale "no pre-pinned host keys" line.
- `scripts/reboot-check.sh`, `scripts/tailnet-reboot-check.sh` — host-key
  assertions now check a declared property.
- All future netcup installs (fresh install or re-image) are affected; deploys
  and the running host are not.
- Security-relevant: the deployed SSH host identity becomes installer-derived,
  a deliberate trade stated above.

Cite: <https://devenv.sh/reference/options/#machines> ·
<https://devenv.sh/machines/>
