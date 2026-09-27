## MODIFIED Requirements

### Requirement: The Machine evaluates to a bootable NixOS system

`devenv eval machines.netcup.build.nixos` SHALL return a store path naming a
NixOS system derivation for `x86_64-linux`, without contacting the target. The
evaluation DOES require the secrets declared in the repository's SecretSpec
profile to resolve, because a Machine resolves its whole profile on every
invocation — measured on this repository, and accepted deliberately by
`add-netcup-tailnet` so that the auth key can be delivered by `install.secrets`.

#### Scenario: The system evaluates

- **WHEN** the operator runs `devenv eval machines.netcup.build.nixos` in the
  repository root
- **THEN** it prints a single store path whose name begins
  `nixos-system-netcup-`

#### Scenario: Evaluation requires no secret provider

- **RETIRED 2026-09-27 by `add-netcup-tailnet`.**
- **WHEN** the machine is evaluated on a workstation with no vault session
  available, against this repository as it now stands — which declares
  `TS_AUTH_KEY`
- **THEN** evaluation FAILS rather than succeeding, the inverse of what this
  scenario originally asserted. Its old precondition (a repository with no
  `secretspec.toml`) can no longer be met, because that file now exists and the
  Machine resolves the whole profile on every invocation. The scenario is kept
  here, with the inversion stated, so that the retirement is visible in the
  canonical spec instead of looking like an oversight.

#### Scenario: Evaluation requires the declared secrets to resolve

- **WHEN** the machine is evaluated on a workstation where the `dev` vault is
  not available to SecretSpec, and the repository declares secrets in
  `secretspec.toml`
- **THEN** evaluation fails with a SecretSpec resolution failure naming the
  unresolvable secret, rather than succeeding

#### Scenario: Inspecting the machine is a vault-privileged action

- **WHEN** the operator runs `devenv machines info` in the repository root
  without a usable `dev` vault session
- **THEN** it fails for the same reason as evaluation, so that reading machine
  metadata is no longer possible without the vault