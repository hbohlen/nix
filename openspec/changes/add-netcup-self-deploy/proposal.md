## Why

netcup can only be rebuilt from the operator workstation. `devenv machines deploy`
builds where it runs, so every change to this host requires a second machine to be
present, booted, and holding the vault — and `devenv machines install` requires one
even to recover a host whose only other access route is being changed. The host
runs the NixOS this repository declares, and it is the only machine in the picture
that must be able to reconstitute itself.

The milestone: **netcup carries its own checkout of this repository and rebuilds
its own system, with no second machine in the loop.**

The mechanism is `devenv machines deploy` run *on* the host, against
`root@localhost`. The docs state the two facts that make this the right shape:
"By default, devenv builds on the machine running the command" (so the build is
native and needs no remote builder), and "Setting it to `localhost` still uses
SSH" (so there is no local-activation mode for a NixOS role; the `deploy me`
form in the docs is home-manager-only and does not apply here). The target is
chosen per-invocation with the documented `-O <OPTION:TYPE> <VALUE>` override,
so there is still exactly one Machine declaration and no local/remote drift.

## What Changes

- **New:** a git remote for this repository, and a branch or jj bookmark to push
  it. Measured 2026-09-27: `git remote -v` is empty, the checkout is jj-colocated
  in detached HEAD (`git branch --show-current` empty) and `jj bookmark list` is
  empty — there is nothing to push yet.
- **New:** the host holds a checkout at `/home/hbohlen/nix` and the pinned devenv
  2.4.0 toolchain, so `bin/devenv` works there. Measured: the pinned toolchain
  (`/nix/store/axhrys71dyh0l7gynicv8mfy9y9mjc4i-devenv-wrapped-2.4.0`) **is** in
  `devenv.cachix.org` (`nix path-info --store https://devenv.cachix.org` resolves
  it; `cache.nixos.org` returns 404), so the host downloads it rather than
  compiling the Rust workspace.
- **New:** the host can run nix with `nix-command` and `flakes`. Measured:
  `/etc/nix/nix.conf` carries an empty `experimental-features`, so `devenv`
  cannot run there at all today. A per-invocation `NIX_CONFIG` was sufficient for
  the probes; the durable form is a declared setting.
- **New:** a deploy identity on the host. Measured: `/root/.ssh/` is empty, so
  `ssh root@localhost` returns `Permission denied (publickey)` and
  `nix store ping --store ssh://root@localhost` fails to start the connection.
  Self-deploy cannot work until a private key exists on the host whose public
  half root authorizes.
- **New:** the host is a trusted nix user (or the deploy runs as root, which it
  must anyway). Measured: `trusted-users = root` in `/etc/nix/nix.conf`, so a
  non-root copy to the host's store fails the signature check — the same failure
  already recorded for non-root deploy.
- **New:** `pkgs.git` on the host. Measured: `command -v git` on the host is
  absent, along with `op`, `devenv` and `jq`.
- **New:** the vault is resolvable on the host, because every `devenv machines`
  invocation resolves the whole SecretSpec profile — deploy uses no secret value,
  but resolution still happens. Measured 2026-09-27, with the manifest present
  and no `OP_SERVICE_ACCOUNT_TOKEN`: `machines info` exits 1 with
  `No accounts configured for use with 1Password CLI`.
- **New:** a `netcup-self-deploy` capability, a verification suite in the shape
  the two archived changes established, and a procedure document.
- **Not in this change:** closing root login, changing `PermitRootLogin`,
  confining sshd to the overlay — that is the hardening follow-up, and this
  change constrains it rather than performing it. No disk-layout change, no
  `install`, no re-image, no new port, no new secret item in the vault.
- **Dropped relative to `~/projects/nixos`:** nothing, because there is nothing
  to drop — a search of that repository for `self-deploy`, `self-host`,
  `root@localhost` finds no match in its tracked files. The reference never
  deployed from the host; this change is not inheriting a mechanism, it is
  acquiring one.
- **Contradicted relative to `~/projects/nixos`, deliberately and narrowly:**
  ADR-0005 states the operator environment *runs on netcup* and allows a vault
  client on the public VPS under blast-radius rules; ADR-0006 challenges that
  premise because the workstation is now `contabo`. This change restores one
  narrow piece of ADR-0005's posture — the deploy path, and the vault
  resolution it needs, live on the host — without moving the operator shell,
  which stays on the workstation. ADR-0005's blast-radius rules are the
  precedent this change cites for its credential decision, not a decision it
  inherits.

## Capabilities

### New Capabilities

- `netcup-self-deploy`: netcup builds and activates its own system from a
  checkout on itself — the repository has a pushable history and the host
  carries that checkout, the host satisfies the preconditions a `deploy` run
  there needs (a nix with features enabled, a trusted user, a deploy identity
  for `root@localhost`, the vault resolvable), the deploy runs against a
  loopback target with no second declaration, the host's system can be rebuilt
  without a workstation, and each of those claims has evidence that can be
  re-read.

### Modified Capabilities

**None.** No existing requirement's own behavior changes, and the reasoning is
worth stating so it can be disagreed with explicitly:

- *`netcup-machine` — "Remote access is key-only SSH on the target's public
  address."* Unchanged. It already authorizes the operator's ed25519 key for
  root "because the `devenv machines` install and deploy paths require root
  SSH", and the new loopback path uses that same identity. It scopes itself to
  the target's *public address*; a loopback deploy target is a different
  surface and belongs to the new capability. What this change does do is make
  that requirement **permanent** — after it, root SSH can never be closed — and
  that consequence is recorded under Impact and in the design's open questions,
  because it is the hardening follow-up's decision to make, not this change's to
  spec.
- *`netcup-tailnet`* — unchanged, and deliberately protected: its
  install-time enrollment property depends on `install.secrets`, which depends
  on `secretspec` being enabled. The mechanism chosen here keeps the manifest
  and the manifest's consumers exactly as they are.
- *`netcup-operations` — "Host-touching commands run where the operator can
  watch them."* Unchanged and still satisfied: a self-deploy is wrapped as an
  SSH invocation inside a bb pane like any other host-touching step, and the
  requirement is about visibility, not about which side of the connection the
  process runs on. Its *wrapper* gains a host-side variant, which is an
  implementation detail of the new capability rather than a change to that
  requirement.
- *`netcup-install`* / *`netcup-disk-layout`* — untouched. Installs keep running
  from outside the host, because a host cannot kexec into an installer to wipe
  its own disk.

One alternative would change this section: if the vault is instead taken off the
`machines` path by setting `secretspec.enable: false` in `devenv.yaml`
(measured to work), then `netcup-machine`'s scenarios *Evaluation requires the
declared secrets to resolve* and *Inspecting the machine is a vault-privileged
action* become false again and need a MODIFIED delta — and, more seriously,
`netcup-tailnet`'s install-time enrollment loses its delivery mechanism. That
alternative is argued and rejected in the design; naming it here is what makes
the rejection reviewable.

## Impact

- **Repository:** adds the verification scripts and a procedure document, and a
  host-package declaration; modifies `devenv.nix` (the host's nix settings and
  `pkgs.git`) and `hosts/netcup/default.nix` or a sibling module. The capability
  spec lands under `openspec/specs/netcup-self-deploy/` when this change is
  archived.
- **Version control:** this repository has no remote. The remote's identity and
  the branch or bookmark name are operator decisions, not derivable here —
  recorded as an open question rather than guessed.
- **Host:** a checkout under `/home/hbohlen/nix`, the pinned toolchain in the
  store, `git`, a nix configuration change, and a private key at rest for
  `root@localhost`. The host is live and productive; every step that writes to
  it is delivered by `deploy`, never by `install`, so no re-image is required.
- **Vault:** unchanged in content. What changes is where it must be *reachable*:
  the host joins the workstation as a place a SecretSpec profile can resolve.
  This is the change's one new trust decision, and it is argued in the design
  against the alternative of removing the manifest from the path.
- **The hardening follow-up:** this change makes root SSH load-bearing
  permanently, so "close root login" is no longer available as written. It also
  constrains *how* root can be confined: a `Match Address` block scoped to the
  tailnet would not match `127.0.0.1`, so a loopback self-deploy would fall back
  to the global `PermitRootLogin` and stop working. Any hardening spec must
  include loopback in whatever it permits, or this change's daily loop breaks.
- **Not reachable without an outside machine, and named so it is not confused
  with a goal:** the first install and every later re-image. `install` kexecs a
  temporary installer over root SSH from outside and cannot run on the host it
  is about to partition.
- **Pre-existing, not this change's:** `devenv machines check netcup` reports
  `Warning [access-analysis-incomplete]` for the host's `dynamicKeys = true` SSH
  facts, already recorded in the archived tailnet change's proposal. It is
  unrelated to this work and will still be reported after it.
