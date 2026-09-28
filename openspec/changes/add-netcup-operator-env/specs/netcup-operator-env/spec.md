## Purpose

The operator account `hbohlen` on the netcup host: the user-level environment a
human or agent works from after logging in — which tooling lands on `PATH`, how
it is deployed, where project work lives, and how its credentials are resolved
without ever at rest. Carried by a home-manager role on the same Machine as the
system role, so it deploys through the existing loop and survives a re-image the
same way the system configuration does. How the machine itself is declared is
`netcup-machine`; how the host rebuilds itself is `netcup-self-deploy`.

## ADDED Requirements

### Requirement: The operator's environment is a home-manager role on the existing Machine

The repository SHALL declare the operator's user-level environment as a
`home-manager` role on `machines.netcup` — reusing the Machine's `target.host`
and `target.sshOpts`, with no second Machine declaration and no second SSH
identity — configured with `home.username` and `home.homeDirectory` naming
`hbohlen` and a `home.stateVersion`.

#### Scenario: The role activates as the operator, not as root

- **WHEN** a deploy of the machine completes
- **THEN** the home-manager activation has run as uid `hbohlen` with
  `HOME=/home/hbohlen` (devenv's activation driver drops from root via
  `runuser`, falling back to `sudo`), and the files it creates are owned by
  `hbohlen`

#### Scenario: The system role activates first

- **WHEN** a deploy of the machine runs
- **THEN** the system role activates before the home-manager role, so a system
  activation failure is never masked by a user-environment failure

#### Scenario: No second SSH identity or target is introduced

- **WHEN** `devenv.nix` is read after the change
- **THEN** `target.sshOpts` still names exactly one key path with
  `IdentitiesOnly=yes`, `target.host` is unchanged, and no second machine
  declaration exists — the role reaches the host over the existing root target
  and is dropped to the operator at activation time

### Requirement: The operator runs the repository's pinned devenv version

`hbohlen`'s profile SHALL provide a `devenv` executable whose version equals
`bin/devenv --version`, SHALL derive it from the repository's locked `devenv`
input, and SHALL NOT use `pkgs.devenv` from this Machine's nixpkgs.

#### Scenario: Both names answer the same version on the host

- **WHEN** `devenv --version` and `./bin/devenv --version` are run as `hbohlen`
  at the checkout on the host
- **THEN** both report the same version, 2.4.0 or newer, so the two names never
  disagree the way they do on the workstation

#### Scenario: The package and the module pin are one revision

- **WHEN** the revision `devenv.lock` pins for the `devenv` input is compared
  with the source the role's devenv package is built from
- **THEN** they are the same revision, so the CLI and the machines modules
  cannot drift apart

#### Scenario: The nixpkgs devenv is not the one installed

- **WHEN** the operator module is inspected for where its devenv package comes
  from
- **THEN** it references the locked `devenv` input rather than `pkgs.devenv`,
  which measures 2.3.1 on this Machine's nixpkgs and has no `machines`
  subcommand

### Requirement: The GitHub CLI is installed and authenticates per use with no token at rest

`gh` SHALL be in the operator's profile, and its credential SHALL be the
`GH_TOKEN` entry declared in `secretspec.toml`, resolved by SecretSpec at the
moment of use. The GH token's value SHALL NOT exist in the repository, in the
Nix store, in the environment a shell starts with, or at rest anywhere on the
host.

#### Scenario: gh is available to the operator

- **WHEN** `gh --version` runs as `hbohlen` on the host
- **THEN** it reports an installed version rather than "command not found"

#### Scenario: Authentication happens at the moment of use

- **WHEN** `secretspec run`, given a reason, executes a `gh` command that needs
  authentication (such as `gh auth status`)
- **THEN** `GH_TOKEN` resolves from the `dev` vault for that invocation only
  and `gh` reports the authenticated account

#### Scenario: The manifest declares without holding

- **WHEN** `secretspec.toml` is read
- **THEN** the `GH_TOKEN` entry names its description, its provider, and its
  `dev` vault item reference, and contains no token value — and the manifest's
  existing `TS_AUTH_KEY` entry is untouched

#### Scenario: No GH token value is at rest

- **WHEN** the repository, the Nix store, and the paths this change adds on the
  host are searched for the token
- **THEN** no token value appears in the tree, the store, or any file on the
  host — authentication reads it from the vault each time

#### Scenario: The profile still resolves on both machines

- **WHEN** `devenv machines info` runs after the entry is added, in the
  repository root on the workstation and at the checkout on the host
- **THEN** both exit 0: the new secret resolves under each machine's existing
  credential, and the self-deploy loop is not broken by the declaration

### Requirement: The operator's home provides a writable projects root

The home-manager activation SHALL create `/home/hbohlen/projects` as a real,
writable directory owned by `hbohlen`, never a symlink into the read-only Nix
store.

#### Scenario: The directory exists and is usable after a deploy

- **WHEN** a deploy activates the home-manager role
- **THEN** `/home/hbohlen/projects` exists, is a directory owned by `hbohlen`,
  and the operator can create files in it

#### Scenario: The directory is not a store symlink

- **WHEN** the path is inspected with `ls -ld` and `readlink`
- **THEN** it is a real directory, not a symlink to `/nix/store`

#### Scenario: A hand-created directory survives activation

- **WHEN** activation runs on a host where the operator already created the
  directory by hand
- **THEN** activation succeeds without error and does not replace or remove it
