# netcup-machine Specification

## Purpose
TBD - created by archiving change add-netcup-bare-install. Update Purpose after archive.
## Requirements
### Requirement: The netcup host is declared as a devenv Machine

The repository SHALL declare the netcup host as `machines.netcup` in
`devenv.nix`, with `system = "x86_64-linux"` and a `target.host` naming the
address the installer connects to. The declaration SHALL be the only surface
that defines this host's NixOS configuration.

#### Scenario: The Machine is enumerable

- **WHEN** the operator runs `devenv machines info` in the repository root
- **THEN** the listing contains a machine named `netcup` with system
  `x86_64-linux` and role `nixos`

#### Scenario: No competing host-definition surface exists

- **WHEN** the repository is inspected for a `flake.nix` exporting
  `nixosConfigurations.netcup`, and for a host-assembly function such as
  `lib/mkHost.nix`
- **THEN** neither exists, because devenv builds a Machine's module list itself
  and would never call such a function

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

### Requirement: The host's NixOS version is stated explicitly

The configuration SHALL set `system.stateVersion` to the release the host is
first installed with, so a later nixpkgs change cannot silently migrate the
host's stateful defaults.

#### Scenario: stateVersion is set by this repository

- **WHEN** `system.stateVersion` is read from the Machine's evaluated
  configuration
- **THEN** it is an explicit release string set in this repository, not a
  nixpkgs default

### Requirement: The configuration does not depend on generated hardware facts

The Machine SHALL take its hardware configuration from a module in this
repository, and SHALL NOT require a `nixos-facter` input or a generated
`facter.json` report. A machine with no facter report MUST still evaluate.

#### Scenario: No facter dependency

- **WHEN** `devenv.yaml` is inspected for a `nixos-facter-modules` input, and
  the Machine's `hardware.facter` option is read
- **THEN** no such input is declared and `hardware.facter` is null

### Requirement: The host boots over UEFI without console intervention

The installed host SHALL boot through UEFI using systemd-boot, with the EFI
system partition mounted at the bootloader's `efiSysMountPoint` and NVRAM
writes disabled, so a first boot after install needs no operator at the
provider console.

#### Scenario: Boot succeeds unattended

- **WHEN** the installer reboots the host after a successful install
- **THEN** the host reaches a running system and answers SSH without console
  input, and `bootctl status` reports the booted entry

### Requirement: Remote access is key-only SSH on the target's public address

The configuration SHALL enable sshd on port 22, SHALL disable password
authentication for every account, SHALL authorize the operator's ed25519
identity — the 1Password `dev` vault item `SSH Key`, fingerprint
`SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ` — for the non-root
operator account, and SHALL authorize that same key for root, because the
`devenv machines` install and deploy paths require root SSH. The identity
SHALL be materialized from the vault at the moment of use (`op inject` into a
`0600` file) and SHALL NOT be carried in an environment variable; no private
key material SHALL be stored in this repository or in the Nix store.

#### Scenario: The identity is proven by fingerprint

- **WHEN** the materialized key's derived public key is compared against the
  vault item's `fingerprint` field
- **THEN** the two fingerprints are equal, and no private key material was
  printed to the terminal or written anywhere but the `0600` file

#### Scenario: The operator key authenticates

- **WHEN** the operator connects to the target's public address as the
  non-root operator account using that key
- **THEN** the login succeeds

#### Scenario: Root is reachable with the same key

- **WHEN** the operator connects to the target as root using that key
- **THEN** the login succeeds, satisfying the install and deploy requirement

#### Scenario: Only the SSH port is exposed

- **WHEN** the evaluated machine's firewall facts are read
- **THEN** the firewall is enabled, port 22 is the only allowed TCP port, and no
  port ranges are allowed

#### Scenario: Password authentication is refused

- **WHEN** a login is attempted with a password for any account
- **THEN** the server refuses it, and the account has no usable password

#### Scenario: No private key material is committed

- **WHEN** the repository and the Nix store are searched for the operator's
  private key or any other secret value
- **THEN** only the public half of the key appears

