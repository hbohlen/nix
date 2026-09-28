# Proposal: decide-agent-runner-service-model

## Why

The last open devenv-feature opportunity (item 13 in
`docs/devenv-feature-opportunities.md`; `docs/handoff-followups.md` ledger #10) is
how an **always-on agent job** would run on netcup. The tempting answer — `devenv
processes` / `devenv up` — cannot satisfy it: devenv's process manager is
**session-scoped**, a process lives only for the duration of its run, and
`devenv tasks run` stops every process it started when the graph finishes. Left
unrecorded, a future concrete runner would re-derive this from the docs (or,
worse, from a job that silently dies at logout) and would also rediscover a
coupled host constraint: `trusted-users` on the netcup host is `root` only, so a
non-root build silently loses a substituter supplied per invocation. This change
records the model and its constraints now, while there is no concrete agent to
bias the answer.

**Milestone:** housekeeping on the second milestone (the host runs its declared
NixOS, with a tailnet, a self-deploy loop, and an operator environment). It
advances no host capability and adds no moving part; it fixes the model a later
agent-runner change will build on, so that change starts from a stated decision
instead of rediscovering one.

## What Changes

- **Decision recorded: an always-on agent job on netcup is a NixOS `services.*`
  unit, or a lingered user unit (`users.users.<name>.linger` and the systemd
  user manager).** `devenv processes` / `devenv up` is explicitly **NOT** the
  mechanism for a boot-surviving job.
- **The decision is grounded in the documented process-manager semantics** rather
  than in taste: a process lives for the duration of its run; the manager is
  session-scoped (tied to a login, dies with it); and `devenv tasks run` stops
  every process it started when the graph finishes. `devenv up -d` detaches only
  within a session, and a config change is not picked up by an attach
  (`devenv processes down && devenv up -d` restarts it). Sources:
  <https://devenv.sh/processes/> and
  <https://devenv.sh/tasks/#processes-as-tasks>.
- **`devenv processes` is not discarded — it is scoped.** It remains the right
  tool for interactive and dev-time helpers (readiness probes, restart policies,
  watchdog, socket activation) whose lifetime is a shell, not a boot. Only the
  boot-surviving case is excluded from it.
- **Coupled enabler for non-root host-side builds recorded.** Because the nix
  daemon **silently drops an untrusted user's `--option extra-substituters`**
  (measured 2026-09-28 on the workstation, nix 2.34.x: an `nix-store -r` probe
  run as an untrusted user never contacted a bogus cache, while the identical run
  as root did), and because the netcup host's `trusted-users` is `root` only, a
  non-root runner can only substitute if the **host declares** `devenv.cachix.org`
  in `nix.settings.substituters` **and** `nix.settings.trusted-public-keys`. The
  host already carries both (added by `add-netcup-self-deploy` in
  `hosts/netcup/self-deploy.nix`, via `lib.mkAfter` so `cache.nixos.org`
  survives); `trusted-users` was deliberately left `root`-only, and widening it
  is a permanent privilege grant a future change must decide explicitly rather
  than default to.
- **What remains to be verified is stated, not assumed:** `users.users.<name>.linger`
  is confirmed present in the NixOS manual, but has **not** been evaluated
  against the locked nixpkgs — that eval is owed before any lingered-unit design
  is trusted. The unit type and scope for a concrete runner are likewise not
  chosen here.
- **No host is touched and no service is declared.** There is no concrete agent
  to run, so this change adds no NixOS module, no `systemd.services` entry, no
  `users.users` change, and no config. It records the model and its constraints
  so a future concrete runner does not rediscover them.

**Non-goals, stated explicitly:**

- Not implementing, declaring or deploying any agent, service, unit or timer.
  The live host, its firewall, its SSH posture and its users are untouched.
- Not choosing the runner's technology, unit scope (system vs user), sandboxing,
  restart policy, or secret delivery (sops-nix/agenix remain undiscussed,
  ledger #9).
- Not widening `trusted-users`, and not changing `nix.settings` — the cache and
  key already exist; whether a non-root runner justifies the permanent grant is
  deferred to the change that introduces a concrete runner.
- Not the posture change (tailnet-only access, ledger #3), not the console
  R-A/R-B design (ledger #2), and not the install-time `TS_AUTH_KEY` delivery
  proof (ledger #4).
- Not touching the `netcup-task-graph` or `netcup-operations` surfaces: tasks are
  not processes, and this change does not restate the watchability requirements.

**Dropped / contradicted relative to `~/projects/nixos` (reference, not truth):**
the reference repo keeps its long-running `dsh` backend **in an operator devenv
shell** (loopback only) rather than as a declared unit — `modules/nixos/dsh-tailnet-endpoint.nix`
states "The dsh process itself (runs in the operator devenv shell, loopback
only)". This change **contradicts that posture**: a long-running job that must
outlive a login is a `services.*` unit or a lingered user unit, never a
session-scoped operator process. No mechanism is inherited by copying — the
reference declares no lingering/service model to reuse, and its shell-run posture
is declined.

**Sources:** <https://devenv.sh/processes/> ·
<https://devenv.sh/tasks/#processes-as-tasks> · the NixOS manual's
`users.users.<name>.linger`.

## Capabilities

### New Capabilities

- `netcup-agent-runner`: the boot-surviving service model for always-on agent
  work on netcup — the requirement that such a job is a NixOS `services.*` unit
  or a lingered user unit and explicitly **not** a session-scoped `devenv
  processes` / `devenv up` job, together with the constraints that bind it: the
  non-root host-side build enabler (host-declared `devenv.cachix.org` in
  `nix.settings.substituters`/`trusted-public-keys`, `trusted-users` root-only and
  not to be widened by default), and the open items this model carries (the
  `users.users.<name>.linger` eval against the locked nixpkgs; the unit type for a
  concrete runner). It records the model only — it declares no service, because
  no concrete agent exists.

### Modified Capabilities

- None. No existing capability's requirements change. `netcup-self-deploy`'s
  preconditions requirement ("The deploying identity is trusted or is root") and
  its "A local build does not need the workstation's store" scenario remain
  satisfied exactly as written: the host already declares the substituter and its
  key, and the deploy identity is root. `netcup-operations` and
  `netcup-task-graph` are unaffected (tasks are not processes), and the access,
  install, disk and tailnet capabilities are untouched. Listing them as not
  modified is deliberate and reviewable.

## Impact

- **Repository:** one new capability spec, `openspec/specs/netcup-agent-runner/spec.md`,
  written in this change's specs phase and landing when the change is archived;
  plus this change's own artifacts. No existing spec file is edited. When
  archived, `docs/handoff-followups.md` ledger #10 moves from "open" to "closed —
  decision recorded", and item 13 of `docs/devenv-feature-opportunities.md` is
  answered.
- **Host / vault / toolchain:** none. Nothing in this change contacts the target,
  the Nix store, or 1Password, so no eval-or-check gate is required before any of
  them.
- **Configuration:** none. `devenv.nix`, `hosts/netcup/*`, `secretspec.toml` and
  `scripts/*` are unchanged. The substituter/`trusted-public-keys` declaration
  already exists in `hosts/netcup/self-deploy.nix`; this change only records why a
  future non-root runner depends on it.
- **`~/projects/nixos`:** the reference's shell-run long-lived process posture is
  contradicted, as stated above; nothing is dropped from its decisions, and its
  ADRs and module split remain reference-only.
- **Consequences for later changes:** a future concrete agent-runner change now
  starts from a stated model (systemd unit or lingered user unit) and a stated
  host constraint (declared substituter; `trusted-users` root-only), instead of
  rediscovering both. No later change is bound by this one beyond that.
