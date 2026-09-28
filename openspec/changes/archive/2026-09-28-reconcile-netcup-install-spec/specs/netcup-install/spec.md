## ADDED Requirements

### Requirement: The install path resolves the repository's SecretSpec profile and needs no overlay membership

The install SHALL run only from a workstation where the repository's SecretSpec
profile resolves: `devenv machines install` resolves the whole profile, as
every `devenv machines` invocation does, so the secrets this repository
declares — currently `TS_AUTH_KEY`, mapped to `/var/lib/tailscale/authkey` by
`machines.netcup.install.secrets` — SHALL be resolved before the irreversible
step. A run whose profile does not resolve SHALL fail naming the unresolvable
secret rather than partitioning the target.

The install SHALL NOT depend on the target holding overlay membership: the
installer connects to the target's public address, and the target has no
overlay membership at any point during the run. Enrollment begins at first boot
from the delivered file, which `netcup-tailnet` owns — this capability states
only that the install itself does not require it. (The equivalent property at
declaration time is owned by `netcup-machine`.)

#### Scenario: The install runs only where the profile resolves

- **WHEN** the install is run on a workstation where the `dev` vault does not
  resolve, against this repository as it now stands — which declares
  `TS_AUTH_KEY`
- **THEN** it fails with a SecretSpec resolution failure naming the
  unresolvable secret, rather than proceeding to partition the target

#### Scenario: The target is reached directly

- **WHEN** the installer connects to the target
- **THEN** it uses the target's public address, the target has no overlay
  network membership at any point during the install, and no step of the
  install requires the target to have joined one

#### Scenario: The profile is resolved before the irreversible step

- **WHEN** the install is run to its partitioning step with the profile
  resolvable
- **THEN** the declared secrets resolve before any formatting command is issued,
  so a missing credential stops the run while the target is still intact

## REMOVED Requirements

### Requirement: The install path requires no vault session and no tailnet

The install SHALL complete from a workstation with no secret provider
configured and no vault session available, and without the target joining any
overlay network. Neither the evaluation nor the install run SHALL resolve a
secret or contact a vault. (The equivalent property at declaration time is
owned by `netcup-machine`.)

#### Scenario: Install runs with no provider configured

- **WHEN** the install is run on a workstation with no vault client session and
  no `secretspec.toml` in the repository
- **THEN** it proceeds without requesting or resolving a secret

#### Scenario: The target is reached directly

- **WHEN** the installer connects to the target
- **THEN** it uses the target's public address, and the target has no overlay
  network membership at any point in the install

**Reason**: The requirement's precondition — a repository with no
`secretspec.toml` — has not been met since `add-netcup-tailnet` added that
file, mapped `TS_AUTH_KEY` through `machines.netcup.install.secrets`, and
measured that every `devenv machines` invocation, read-only `info` included,
resolves the whole profile. Install therefore resolves a secret by design and
the first half of the requirement is false of this repository. Its second half
— the target needing no overlay membership during the run — remains true and
is carried forward.

**Migration**: Replaced by **The install path resolves the repository's
SecretSpec profile and needs no overlay membership**, which states the vault
requirement in the affirmative (the run fails, naming the secret, when the
profile does not resolve) and keeps the no-overlay half unchanged. The retired
scenario *"Install runs with no provider configured"* is inverted there as
*"The install runs only where the profile resolves"*; *"The target is reached
directly"* carries over.
