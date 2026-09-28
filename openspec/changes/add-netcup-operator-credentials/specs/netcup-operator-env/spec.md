## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: The operator account holds the vault credential, not only root

The host's operator account `hbohlen` SHALL be able to resolve the SecretSpec
profile without root, because `hbohlen` is the account a human or an agent
works from. Its vault credential SHALL be a file owned by `hbohlen` with mode
`0600`, delivered by activation and never through the Nix store. Root's
existing credential SHALL remain, because the self-deploy loop runs as root —
this is a second holder, not a move.

#### Scenario: The operator resolves the profile as itself

- **WHEN** `secretspec check --no-prompt --json` runs as `hbohlen` on the host
  with its own credential in the environment
- **THEN** both `GH_TOKEN` and `TS_AUTH_KEY` report `resolved`, with no prompt
  and no read of root's file

#### Scenario: The credential is the operator's, at rest, unreadable to others

- **WHEN** the operator's credential file is inspected on the host
- **THEN** it is owned by `hbohlen`, mode `0600`, outside the Nix store, and
  its value is never printed by any check — mode, owner and a digest prefix are
  read instead

#### Scenario: Root keeps its copy, so the loop is unaffected

- **WHEN** root's credential file and a root-side `machines` invocation are
  inspected after the change
- **THEN** root's file is unchanged (still root-owned `0600`) and the loop's
  profile resolution still succeeds, so adding the operator's credential did
  not replace the loop's

### Requirement: gh authenticates through a resolving wrapper, with no persisted login

On the host, the `gh` on `hbohlen`'s `PATH` SHALL be a wrapper that resolves
`GH_TOKEN` through SecretSpec for the single invocation and executes the real
`gh` with that value in the environment. `gh`'s own at-rest credential store
(`~/.config/gh/hosts.yml`) SHALL NOT be created on the host, so no PAT persists
in plaintext under the working account.

#### Scenario: Bare gh works as the operator

- **WHEN** `gh auth status` is run as `hbohlen` on the host with no secret in
  the shell environment
- **THEN** it reports the authenticated `hbohlen` account — the wrapper
  resolved the token for that invocation, and the operator did not type
  `secretspec run`

#### Scenario: No token is written by using gh

- **WHEN** the operator's home is inspected after `gh` commands have been run
- **THEN** no `~/.config/gh/hosts.yml` exists, no `GH_TOKEN` is present in a
  shell that has not invoked the wrapper, and no file under the operator's home
  contains the token value

#### Scenario: The wrapper passes arguments through unchanged

- **WHEN** a `gh` command with arguments and flags is run on the host
- **THEN** the arguments reach the real `gh` unchanged, so the wrapper is not a
  narrower interface than `gh` itself

#### Scenario: The wrapper does not shadow a non-gh command

- **WHEN** the operator's tooling looks up any command other than `gh`
- **THEN** only `gh` resolves to a wrapper — no other name is intercepted, and
  the underlying secretspec and devenv binaries remain directly reachable
