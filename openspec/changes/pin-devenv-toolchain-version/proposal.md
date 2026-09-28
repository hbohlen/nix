# Proposal: pin-devenv-toolchain-version

## Why

The repository requires devenv 2.4+ (the version that provides `machines`) and
pins 2.4.0 in three places, but the rule that keeps the running CLI and the
locked modules in agreement — "always use `./bin/devenv`, never bare `devenv`,
on this workstation" — lives only in prose (`bin/devenv`, `devenv.nix`,
`docs/handoff-followups.md` §6). The workstation's bare `devenv` is 2.2.2, so the
wrong binary currently fails late and confusingly
(`Failed to get attribute 'devenv.config.machinesMeta'`) instead of at the
version boundary. Separately, `devenv.yaml:40` still uses the top-level
`allow_unfree` key, which the pinned CLI's own JSON Schema marks `deprecated`
— and that key gates the host's unfree `pkgs._1password-cli`, so an unmeasured
removal would be a silent regression. This addresses items 2 and 3 of
`docs/devenv-feature-opportunities.md`.

This change advances the **toolchain-integrity** stage that the install and
self-deploy milestones already depend on: the deployed host must run exactly the
toolchain the repo locks (`netcup-self-deploy`'s "pinned toolchain" requirement),
and the declarative key that lets that host evaluate its `op` package must remain
valid. It turns two latent, prose-or-schema-only invariants into enforced ones.
It is config hygiene — no new moving part.

## What Changes

- **Add `require_version` to `devenv.yaml`.** The repo pins devenv 2.4.0 in three
  places — `bin/devenv`'s build tag `github:cachix/devenv/v2.4.0#devenv`, the
  `devenv:` input `github:cachix/devenv/v2.4.0?dir=src/modules`, and
  `hosts/netcup/operator.nix`, which derives the host package from that locked
  input — and the binary and the modules must agree. `require_version` enforces
  CLI==modules version; `">=2.4"` is the constraint-string form. Because the
  intent is exact agreement with the locked input rather than a floor, this
  change uses `require_version: true`. A bare 2.2.2 `devenv` then fails with a
  clear version error instead of mid-command. Source:
  <https://devenv.sh/reference/yaml-options/>; the option was added in 2.1
  (<https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/>).
- **Fix the deprecated unfree key.** Move `devenv.yaml:40`'s top-level
  `allow_unfree: true` to `nixpkgs.allow_unfree: true`. The pinned CLI's own
  schema marks the top-level key `"deprecated": true` while
  `$defs/Nixpkgs.allow_unfree` is the live key, documented "Added in 1.7"
  (verified 2026-09-28: <https://devenv.sh/devenv.schema.json>, also
  <https://devenv.sh/reference/yaml-options/>). The key is load-bearing: it is
  the documented route — a Machine module may not set `nixpkgs.config` — that
  lets the host's `pkgs._1password-cli` (`hosts/netcup/self-deploy.nix`)
  evaluate at all. **Measurement caveat:** the deprecated top-level form may
  still function; verify the nested key against the pinned 2.4.0 before removing
  the old spelling, and keep the file's existing reasoning comment.
- **No host touch.** Both edits are confined to `devenv.yaml`: no `devenv.nix`,
  module, secret, vault, deploy, or re-image.

Non-goals, stated explicitly:

- **Consolidating the three version pins.** `require_version` makes their drift
  loud, but folding `bin/devenv`'s hardcoded tag onto `devenv.lock` is a separate
  hygiene change (`docs/devenv-feature-opportunities.md` Part 3, "three
  coexisting version pins"; `add-netcup-operator-env` already names it a
  non-goal).
- **Replacing the prose rule.** `bin/devenv` and the handoff §6 note stay; the
  schema key adds enforcement, it does not remove the explanation.
- Outside scope: the host's toolchain, the tailnet/root-login posture,
  secretspec, and the vault.

## Capabilities

### New Capabilities

None. This is `devenv.yaml` config hygiene with no new spec-level behavior, so
no `specs/<name>/spec.md` is introduced.

### Modified Capabilities

None. No spec-level requirement changes. `netcup-self-deploy`'s "host runs the
pinned toolchain from its own checkout" requirement already states 2.4+ through
`bin/devenv`; `require_version` enforces that same invariant on the workstation
eval path without altering it. Moving `allow_unfree` under `nixpkgs` is a
spelling correction of an already-declared policy, not a behavior change.

## Impact

- **Files**: `devenv.yaml` only (add `require_version`; `allow_unfree` →
  `nixpkgs.allow_unfree`).
- **Workstation**: every `./bin/devenv …` invocation (2.4.0) continues to work;
  a bare `devenv` (2.2.2) now fails at the version check instead of later. This
  is fail-fast on an already-broken path, not a break of a working one.
- **Host**: unaffected until its next deploy. Its bare `devenv` is also 2.4.0
  and agrees with the locked modules by construction (`hosts/netcup/operator.nix`),
  so `require_version` passes there too. The moved key must evaluate against the
  pinned 2.4.0 or the host's `op` stops evaluating — which is the reason for the
  verify-before-remove gate above rather than a blind flip.
- **Vault / secrets**: unchanged.
- **Reference honesty (`~/projects/nixos`)**: this change **drops nothing** and
  **contradicts nothing** in the prior implementation. That repo pins no devenv
  input and carries no `bin/devenv`; it relies on an ambient devenv and uses the
  same top-level `allow_unfree`. This change deliberately departs from that
  reference rather than inheriting it — the pinning and enforcement exist
  precisely because the reference's ambient-toolchain assumption is the
  late-failure trap documented in `docs/handoff-followups.md` §6. Nothing is
  copied from `~/projects/nixos`.
