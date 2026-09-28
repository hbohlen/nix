# Proposal: harden-netcup-deploy

## Why

`devenv.nix` declares no `machines.netcup.deploy` block, so a deploy uses the
documented default health check (`"true"`), which "verifies only system paths":
if activation returns success the deploy is reported as `succeeded`, even when
the host it leaves behind cannot serve the loop it exists for. The real
post-deploy acceptance logic — store mounted read-write, sshd answering, the
tailnet up, the operator environment intact, the deploy state readable — lives
in `scripts/operator-env-verify.sh`, `scripts/self-deploy-verify.sh`, and
`scripts/postinstall-verify.sh` and is run by hand, after the fact. This change
advances the **deploy-integrity milestone** — the first hardening step after
self-deploy, tailnet and operator tooling landed (`docs/devenv-feature-opportunities.md`
item 1) — by moving a machine-checkable slice of that acceptance into the deploy
transaction itself, where the target-side watchdog can act on it. Primary
sources: <https://devenv.sh/machines/> and
<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>.

## What Changes

- **Add `machines.netcup.deploy.healthCheck` to `devenv.nix`** (string,
  default `"true"`): a command that runs as root on the target, uses absolute
  store paths, and asserts the smallest set of host properties the deploy loop
  depends on (at minimum: `/nix/store` is mounted read-write, sshd answers, the
  tailnet service is active). A failing health check makes the target-side
  watchdog restore the previous system.
- **BREAKING (deploy semantics):** a deploy whose activation succeeds but whose
  declared health check fails now rolls back automatically and is recorded as
  `rolled-back`, where today it is reported as `succeeded`. The acceptance bar
  becomes stricter — a deploy can fail for a reason that is not an activation
  error — and a health check must allow enough time for service startup and SSH
  reconnection lest a slow-but-good deploy be rolled back spuriously.
- **Set `deploy.rollbackTimeout` deliberately** (int, default `300`, range
  `30`–`600`): either the default with its rationale recorded, or a larger value
  if the health check needs to wait for services and SSH. The commitment is that
  the value is explicit in the design, not silently inherited.
- **Re-scope — not delete — the verify scripts.** `operator-env-verify.sh`,
  `self-deploy-verify.sh`, and `postinstall-verify.sh` remain the read-only,
  human-readable evidence and carry the fuller acceptance suite (key
  fingerprints, home-manager state, the loop record). They stop being the *only*
  acceptance path; they do not become redundant.
- **Record the residual gap where it is load-bearing.** The health check runs as
  root and gates the NixOS rollback; home-manager is a second activation that
  NixOS rollback does **not** revert (`hosts/netcup/operator.nix`). This change
  cannot make a home-manager activation failure safe, and says so rather than
  implying coverage it does not have.

### Non-goals, stated explicitly

- **Not the hardening change.** Closing root login or making the tailnet the
  only access path (`docs/handoff-followups.md` follow-ups 1/3) stays separate;
  this change touches no SSH, firewall, or access fact.
- **Not a removal of the verify scripts**, and not the `tasks.*` / `enterTest`
  restructuring of the preflight → deploy → verify chain
  (feature-opportunities items 4/5) — its own future change.
- **Not `machines check` / `plan` / `apply` adoption** (items 6/7),
  `require_version` (item 2), or `install.copyHostKeys` (item 8).
- **Not a deliberate break-and-rollback drill.** The rollback behavior is
  specified and read back through the existing `machines status` evidence; the
  destructive rehearsal stays a future action, as in the reference.
- No re-image, no new secret, no new vault item, no change to the SecretSpec
  profile or to any secret's at-rest posture.

## Capabilities

### New Capabilities

None. The change hardens behavior an existing capability already owns.

### Modified Capabilities

- `netcup-self-deploy`: the requirement **"A failed self-deploy restores the
  previous system instead of stranding the host"** broadens from a failed
  *activation* to a failed *activation or declared health check*, and gains the
  declaration of a machine-checkable health check as the deploy's acceptance
  gate. A delta spec adds the health-check requirement plus a scenario that a
  deploy passing activation but failing the health check is recorded as
  `rolled-back` and the host remains reachable. It also records that the gate
  covers the system role only and does not revert home-manager.

## Impact

- **Files:** `devenv.nix` (new `machines.netcup.deploy` block);
  header/comment truth-ups in `scripts/operator-env-verify.sh`,
  `scripts/self-deploy-verify.sh`, `scripts/postinstall-verify.sh` (their role
  as evidence, not gate — no logic change). No `secretspec.toml`, `devenv.yaml`,
  or `hosts/netcup/*` change.
- **Host:** the next `machines deploy` — the routine self-deploy loop over
  `root@localhost` — runs with the stricter gate and can now roll back a deploy
  that would previously have been reported `succeeded`. No re-image, no reboot,
  no new precondition.
- **Spec coordination:** `add-netcup-operator-env` (open, not archived) also
  edits the same `netcup-self-deploy` rollback requirement, scoping it to the
  system role and adding a non-root substituter scenario. Whichever change lands
  second must rebase its delta on the other; the two are compatible but not
  independent.
- **Reference honesty:** relative to `~/projects/nixos` this change **drops /
  contradicts** its `deploy-rollback` capability and its
  `deploy.nodes.netcup` wiring: it does not inherit deploy-rs, `magicRollback`,
  `autoRollback`, `confirmTimeout`, or flake-wired `deployChecks`, and it does
  not adopt flake `nixosConfigurations`. It **reuses only the intent** those
  documents encode — a failed day-2 deploy must not strand the host, and the
  confirmation must be generous enough to survive a slow activation — and
  re-implements it with devenv Machines' own target-side watchdog
  (`deploy.healthCheck` / `deploy.rollbackTimeout`). Nothing else is inherited by
  copying.
