# netcup-disk-layout Specification

## Purpose
TBD - created by archiving change add-netcup-bare-install. Update Purpose after archive.
## Requirements
### Requirement: The layout declares exactly one disk, the host's boot disk

`disko.devices` SHALL declare exactly one disk, device `/dev/vda`, with a GPT
partition table. The layout SHALL NOT declare a second disk, a loop device, or
a device that is not the host's boot disk. (The pre-flight check that the live
target's boot disk really is `/dev/vda`, before anything is written, belongs to
the `netcup-install` capability.)

#### Scenario: One disk, one device path

- **WHEN** `disko.devices.disk` is read from the Machine's evaluated
  configuration
- **THEN** it contains exactly one entry, whose `device` is `/dev/vda` and whose
  content type is `gpt`

#### Scenario: Nothing else is declared writable

- **WHEN** the evaluated `disko.devices` tree is inspected for further disks,
  `zpool`s, or loop devices
- **THEN** none exist

### Requirement: One EFI system partition carries the bootloader

The layout SHALL declare one partition of type `EF00` sized 1 GiB formatted
`vfat`, mounted at `/boot`, carrying restrictive mount options so the ESP is
not readable or writable by unprivileged accounts. `/boot` SHALL be the value
used as the bootloader's `efiSysMountPoint` (whose ownership of the bootloader
configuration itself is the `netcup-machine` capability's).

#### Scenario: ESP is declared and restrictive

- **WHEN** the ESP partition's content is read from the evaluated configuration
- **THEN** its format is `vfat`, its mountpoint is `/boot`, and its mount
  options include `umask=0077`

#### Scenario: Boot mount points agree

- **WHEN** the ESP mountpoint and the bootloader's `efiSysMountPoint` are
  compared
- **THEN** both are `/boot`

### Requirement: Root is one btrfs partition occupying the whole disk

The layout SHALL declare exactly one further partition, sized `100%` of the
remaining disk, formatted `btrfs`. No unallocated space SHALL be reserved, and
the filesystem SHALL be force-created so a rerun over a partially created
layout is not blocked.

#### Scenario: Root partition takes the rest of the disk

- **WHEN** the root partition's size and filesystem are read from the evaluated
  configuration
- **THEN** its size is `100%` and its content type is `btrfs`

#### Scenario: Only two partitions exist

- **WHEN** the GPT partition set is counted
- **THEN** it contains exactly the ESP and the root partition

### Requirement: A minimal, explicit btrfs subvolume set is declared

Root SHALL be mounted from subvolume `@`, and the layout SHALL additionally
declare `@home` at `/home`, `@nix` at `/nix`, and `@var` at `/var`. Every
subvolume SHALL be mounted with `compress=zstd` and `noatime`. The set is
deliberately minimal: subvolumes that exist only to serve later concerns
(snapshots, agent workspaces, per-project mounts, container storage) are added
by the change that needs them.

#### Scenario: Every declared subvolume is compressed and unset-atime

- **WHEN** each subvolume's mount options are read from the evaluated
  configuration
- **THEN** each option list contains both `compress=zstd` and `noatime`

#### Scenario: Mountpoints are the declared ones

- **WHEN** the subvolume names and mountpoints are read
- **THEN** `@` is at `/`, `@home` at `/home`, `@nix` at `/nix`, `@var` at
  `/var`, and no other subvolume is declared

### Requirement: The layout declares no swap

The layout SHALL NOT declare a swap partition, and the configuration SHALL NOT
declare a swap file. This is a deferral, not a decision against swap: memory
pressure policy is added by the change that measures it.

#### Scenario: No swap anywhere in the layout

- **WHEN** the evaluated `disko.devices` tree and `swapDevices` are inspected
- **THEN** neither declares a swap device of any kind

### Requirement: The layout declares no disk encryption

The layout SHALL NOT declare LUKS or any other encryption layer in this change.
Unattended reboots are a precondition of the install being verifiable without a
console, and no remote-unlock mechanism is in scope.

#### Scenario: No encrypted content is declared

- **WHEN** the evaluated disk layout is inspected for encrypted content
- **THEN** no partition or subvolume declares an encryption layer

