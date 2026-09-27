# netcup-install Specification

## Purpose
TBD - created by archiving change add-netcup-bare-install. Update Purpose after archive.
## Requirements
### Requirement: Preconditions are verified before the irreversible step

Before any partitioning command is issued, the operator SHALL verify four
things and SHALL NOT proceed if any fails: (1) root SSH to the target succeeds
with the operator key; (2) the target's boot disk is presented as `/dev/vda`
and is the installed boot disk; (3) `devenv eval machines.netcup.build.nixos`
returns a store path; (4) `devenv machines info` names the intended target
address. The verification SHALL be recorded, because the next step cannot be
rehearsed or undone.

#### Scenario: All preconditions pass

- **WHEN** all four checks succeed on the target that is about to be installed
- **THEN** the operator proceeds to the install, with the recorded output as
  the evidence that the run was against the intended host

#### Scenario: The boot disk is not where the layout expects it

- **WHEN** the target's boot disk is not presented as `/dev/vda`
- **THEN** the install is not run, and the layout or the target presentation is
  corrected first

#### Scenario: A precondition fails

- **WHEN** any precondition check fails
- **THEN** no partitioning or formatting command is issued against the target

### Requirement: The install is a single command with no bootstrap stage

The host SHALL be installed by one `devenv machines install` invocation. There
SHALL be no separate unhardened NixOS configuration, no `nixos-anywhere`
invocation, and no deploy node used to reach a first boot.

#### Scenario: One command installs the host

- **WHEN** the operator runs the documented install command against a target
  that has a fresh OS with root SSH open
- **THEN** the host is partitioned, installed, and rebooted by that command
  alone

#### Scenario: No second install path exists

- **WHEN** the repository is inspected for a bootstrap `nixosConfigurations`
  target, an `nixos-anywhere` invocation, or a deploy-rs node
- **THEN** none exists

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

### Requirement: A successful install produces recorded evidence

After the install reboots the host, the operator SHALL record evidence that the
host came up as declared: the NixOS version it reports, the mounted subvolumes
and their options, and a successful key-only SSH login to the operator account.

#### Scenario: The host reports NixOS

- **WHEN** the operator runs `nixos-version` on the installed host
- **THEN** it reports a NixOS release, and not the installer's own environment

#### Scenario: The declared subvolumes are mounted

- **WHEN** the mounted filesystems are read on the installed host
- **THEN** `/`, `/home`, `/nix` and `/var` are btrfs subvolumes named `@`,
  `@home`, `@nix` and `@var`, mounted with `compress=zstd` and `noatime`

#### Scenario: Access works over the public address

- **WHEN** the operator connects with the operator key as configured
- **THEN** the login succeeds and the connection was not routed through an
  overlay network

### Requirement: A failed install is recoverable without host access

If the host does not come up, the recovery path SHALL be to re-image the target
from the provider console or panel and rerun the install. No state on the
target SHALL be required to recover, and no step SHALL depend on the previous
attempt having succeeded.

#### Scenario: The host does not boot

- **WHEN** the installed host fails to boot or to answer SSH
- **THEN** the operator re-images the target to a fresh OS with root SSH open
  and reruns the documented preconditions and install, with no cleanup step on
  the failed host

### Requirement: The procedure is recorded in the repository

The repository SHALL document the install procedure: the preconditions and the
commands that check them, the install command, and the post-install evidence
commands. The document SHALL name the target it applies to and SHALL NOT
contain a secret value.

#### Scenario: The procedure is reproducible from the repository

- **WHEN** an operator who did not perform the first install reads the document
- **THEN** they can reproduce the checks, the install command, and the evidence
  commands without inferring any step

#### Scenario: The document carries no secret

- **WHEN** the document is searched for credential values
- **THEN** it names the key by fingerprint only

