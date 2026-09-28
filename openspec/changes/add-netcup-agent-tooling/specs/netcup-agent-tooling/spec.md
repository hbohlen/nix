## Purpose

The agent tooling the operator account `hbohlen` carries on the netcup host:
which executables are installed (`hermes`, `herdr`), where they come from (a
pinned `numtide/llm-agents.nix` flake input, never the Machine's `pkgs`), and the
deliberate consequence of consuming a flake that builds against its own
`nixpkgs` — a second nixpkgs evaluation in the graph, accepted so the packages
substitute from a binary cache instead of compiling.

This capability is scoped to **tooling on `PATH`**. It is not the boot-surviving
service model for always-on agent work (`netcup-agent-runner`, decided separately
by `decide-agent-runner-service-model`), and it declares no credential, no
service, no timer and no shell integration.

## ADDED Requirements

### Requirement: The operator's agent tooling comes from a pinned flake input

The repository SHALL declare `numtide/llm-agents.nix` as a flake input and SHALL
provide `hermes` and `herdr` on the operator account's `PATH` from that input's
`packages.<system>` set. The packages SHALL NOT be sourced from the Machine's
`pkgs`. The input SHALL be pinned in `devenv.lock` and SHALL NOT follow
`nixpkgs`.

#### Scenario: Both tools are on the operator's PATH

- **WHEN** `hermes --version` and `herdr --version` are run as `hbohlen` on the
  host
- **THEN** each reports an installed version rather than "command not found"

#### Scenario: The packages come from the input, not from nixpkgs

- **WHEN** the operator module is inspected for where its `hermes` and `herdr`
  packages come from
- **THEN** it references `inputs.llm-agents.packages.<system>`, and the Machine's
  `pkgs` does not provide either attribute

#### Scenario: The input is pinned

- **WHEN** `devenv.lock` is read after the change
- **THEN** it contains an `llm-agents` node with a resolved revision, and no
  existing node was moved

#### Scenario: The second nixpkgs is deliberate, not accidental

- **WHEN** the installed `hermes` closure is inspected for the nixpkgs revision
  it was built against, and compared with the Machine's `nixpkgs` input
- **THEN** the two differ, because the input does not follow `nixpkgs` — a
  documented exception taken so the packages substitute from the input's own
  binary cache rather than being rebuilt against this Machine's nixpkgs

### Requirement: The tooling is confined to the operator role and does not change access or services

Installing the agent tooling SHALL be confined to the operator's home-manager
role. It SHALL NOT declare a system service, a timer, a lingering user, a port,
or a firewall or SSH change, and SHALL NOT alter the deploy order or the
rollback posture of either role.

#### Scenario: No running process is introduced

- **WHEN** the evaluated configuration is read for systemd services, timers, and
  `users.users.<name>.linger`
- **THEN** none of them carries an entry added by this change — the tools are
  installed, not started

#### Scenario: The access posture is unchanged

- **WHEN** the evaluated machine's firewall and SSH facts are read after the
  change
- **THEN** the firewall is enabled, port 22 is the only allowed TCP port, root
  login remains key-only, and no port range was opened

#### Scenario: The deploy posture is unchanged

- **WHEN** the home-manager role block in `devenv.nix` is read after the change
- **THEN** it is the same single role on the same Machine with the same `target`
  and `sshOpts`, and the system role still activates first
