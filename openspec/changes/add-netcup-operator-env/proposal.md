# Proposal: add-netcup-operator-env

## Why

The host can rebuild itself (self-deploy) and is reachable (tailnet), but the
operator account on it has no user-level environment: `hbohlen` has no `devenv`
on `PATH` (only the checkout-pinned `bin/devenv` behind a gitignored gcroot), no
`gh`, and no declared place for project work — while the recorded follow-ups
explicitly ask whether the host should carry `gh`/`GH_TOKEN` (handoff Q7/Q8) and
whether the operator account should get a home-manager role (self-deploy design
Q7). The workstation is also the only machine that can rebuild the toolchain, so
any non-root build on the host that needs `devenv.cachix.org` silently degrades
(measured: the daemon drops an untrusted user's `--option extra-substituters`
without a word).

This change advances the **operator-tooling** follow-up (handoff ledger #9's
"operator tooling on the host", Q7/Q8) and closes **self-deploy design Q7** —
after install, tailnet and self-deploy landed, as the convention requires.

## What Changes

- **A `home-manager` role on `machines.netcup`** — activated as `hbohlen` after
  the system role (devenv's activation wrapper drops root → `runuser -u
  hbohlen`, so the shared `root@…` target and `sshOpts` are unchanged). Needs a
  hand-added `home-manager` input in `devenv.yaml` (`follows: nixpkgs`, nested
  form). The documented hazard is accepted and will be named in the design: a
  home-manager activation failure leaves the NixOS deploy applied — system
  rollback does not revert home-manager files.
- **`devenv` 2.4.0 on `hbohlen`'s `PATH`**, pinned by deriving the package from
  this repo's already-locked `devenv:` input (devenv's own `devenvPackageFor`
  technique) — **no third version pin**. One devenv version on the host means
  bare `devenv` and `bin/devenv` agree, unlike the workstation.
- **`gh` in the user profile**, and **`GH_TOKEN` declared in
  `secretspec.toml`** (declaration only — the `dev` vault item already exists,
  measured 2026-09-28). Consumed per use via `secretspec run -- gh …`: no token
  at rest on the host, no value in the tree or the store. Cost, accepted like
  `TS_AUTH_KEY` before it: one more secret resolved by *every* `devenv
  machines` invocation, on both machines. The same edit rewrites `secretspec.toml`'s
  stale "the service account is READ-ONLY" comment (disproved 2026-09-28, handoff §9).
- **A declared `~/projects` root** for the host's dev/agent work.
- **`devenv.cachix.org` declared in the host's `nix.settings`** (substituters +
  trusted-public-keys) so non-root builds substitute instead of compiling the
  toolchain from source. `trusted-users` stays `root` (design D5 untouched).
- **Spec deltas**: `netcup-self-deploy` (MODIFIED: rollback requirement scoped
  to the system role; ADD: non-root substituter scenario) and `netcup-machine`
  (MODIFIED: the enumerable-machine scenario lists both roles). New capability
  `netcup-operator-env`.

Non-goals, stated explicitly:

- **The planning root does not move.** Specs, wiki and authored changes stay on
  the workstation — this is user tooling on a target host, not `devenv`'s
  operator shell relocating. (Self-deploy's recorded non-goal stands.)
- **Agent-runner service model** (devenv processes vs systemd units, linger):
  handoff ledger #10, its own future change.
- **`GH_TOKEN` for nix GitHub API rate limits** (`nix.conf access-tokens`):
  unmeasured need, and the delivery design (include-file + bootstrap, store-leak
  forbidden) is its own change. This change only makes the secret resolvable.
- **Consolidating `bin/devenv`'s hardcoded tag onto `devenv.lock`** — two pins
  remain, both already documented; folding them is a separate hygiene change.
- **Declarative `op`/`gh` on the workstation** (it is not a managed machine),
  hardening/closing root login, second host `oci`, `~/projects` project content.

## Capabilities

### New Capabilities

- `netcup-operator-env`: the operator account's user-level environment on the
  host — the home-manager role and its activation order, the pinned devenv and
  `gh` on `hbohlen`'s `PATH`, the declared `~/projects` root, and `GH_TOKEN`
  resolvable through the SecretSpec profile without ever at rest.

### Modified Capabilities

- `netcup-self-deploy`: (1) the failed-deploy rollback requirement is scoped to
  the system role, because a home-manager activation failure leaves the system
  deploy applied and no rollback reverts home-manager files; (2) the nix
  preconditions requirement gains a scenario that a non-root user's builds
  substitute from a cache the host declares (the daemon silently ignores
  client-supplied substituters for untrusted users).
- `netcup-machine`: the "Machine is enumerable" scenario now reports both roles
  (`nixos`, `home-manager`) on the one machine.

## Impact

- **Files**: `devenv.nix` (role block), `devenv.yaml` (hand-added
  `home-manager` input), `secretspec.toml` (`GH_TOKEN` entry + comment truth-up),
  a host module for the role content and the substituter settings (module split
  is a design decision), `docs/handoff-followups.md` (ledger closure at archive).
- **Host**: first deploy after this change activates the home-manager half as a
  second, non-rollback activation; `nix.settings` change requires a deploy (and
  benefits any rebuild after it). No re-image involved.
- **Vault**: unchanged — `GH_TOKEN` already exists in `dev`; nothing is created,
  rotated or written by this change.
- **Both machines**: every `devenv machines` call now resolves `GH_TOKEN` as
  well as `TS_AUTH_KEY` (readable by the host's existing D3 credential; no new
  at-rest secret).
- **Reference honesty**: relative to `~/projects/nixos` — **contradicts ADR-0005**
  ("netcup is the operator's workstation"), whose premise ADR-0006 already
  challenged: this change deliberately puts *user* tooling on netcup while
  keeping the operator shell/planning root on the workstation. It **reuses,
  not contradicts, ADR-0005's blast-radius posture** — no PAT at rest, resolved
  per use from the vault (the `op` service-account credential already at rest
  under D3 is untouched). Nothing else in `~/projects/nixos` is inherited.
