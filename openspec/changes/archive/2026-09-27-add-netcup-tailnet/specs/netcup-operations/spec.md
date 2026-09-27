## ADDED Requirements

### Requirement: Host-touching commands run where the operator can watch them

Every command in this repository that writes to, reboots, or otherwise changes
the netcup host, and every repository script that inspects it, SHALL be executed
in an operator-visible bb terminal pane rather than as a detached command whose
result is reported afterwards. The session identifier SHALL be reported with the
results so the output can be read again later.

#### Scenario: A deploy runs in a pane

- **WHEN** the operator or an agent runs `devenv machines deploy netcup` for this
  host
- **THEN** it runs inside a bb terminal session scoped to the current thread, and
  its progress is visible in the bb app while it runs

#### Scenario: A verification script runs in a pane

- **WHEN** any script in `scripts/` that inspects or enrols the host is run
- **THEN** it runs inside such a pane, and the pane's session identifier is
  reported alongside the verdict

#### Scenario: A purely local evaluation is not forced into a pane

- **WHEN** a step is a single local evaluation such as
  `devenv eval machines.netcup.deploy.facts`, which neither contacts the host nor
  changes anything
- **THEN** it may run inline; the rule is about visibility of host-affecting
  work, not about wrapping every command

#### Scenario: The pane outlives the command

- **WHEN** the wrapped command exits
- **THEN** the pane remains readable, showing the command, its output and its
  exit code, so a script that printed and returned does not become unreadable

### Requirement: The pane's environment is established by the wrapper

A pane does not inherit the invoking shell's environment. The wrapper SHALL
establish the credentials a host-touching command needs before that command
starts, and SHALL NOT cause a secret value to appear in the pane.

#### Scenario: The vault session is available inside the pane

- **WHEN** a command that resolves the SecretSpec profile runs in a pane
- **THEN** the 1Password service-account credential is available to it, taken
  from the workstation's `0600` token file, and the pane reports that it was
  exported

#### Scenario: No secret value reaches the pane

- **WHEN** a pane runs a command that moves the tailnet auth key, or any other
  secret, onto the host
- **THEN** the value travels outside `argv` and the pane's scrollback contains no
  key material — the wrapper reports presence, never value

### Requirement: What a pane was asked to run is recorded on disk

The wrapper SHALL write the exact command it hands to a pane into a file, so that
a pane's purpose can be established after the fact without trusting memory.

#### Scenario: The wrapper is readable afterwards

- **WHEN** a pane has been created for a command
- **THEN** a file under the thread's storage contains that command, and re-reading
  it reproduces the command the pane ran
