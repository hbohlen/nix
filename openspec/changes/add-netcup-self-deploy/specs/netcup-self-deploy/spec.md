## ADDED Requirements

### Requirement: The repository is pushable and the host carries the same history

The repository SHALL have a git remote and a named branch or bookmark, and the
host SHALL hold a checkout at `/home/hbohlen/nix` cloned from that remote. The
host's checkout SHALL be the same revision the workstation pushed, so that a
change made on either side is a change to one history.

#### Scenario: A remote exists and the published revision resolves

- **WHEN** `git remote -v` and the branch or jj bookmark listing are read in the
  repository root
- **THEN** a remote is configured and a named branch or bookmark exists to push
  to, neither of which was present before this change

#### Scenario: The host's checkout is the pushed revision

- **WHEN** the revision at `/home/hbohlen/nix` on the host and the revision at
  the tip of the pushed branch are compared
- **THEN** they name the same commit, and no uncommitted difference exists
  between them that the operator did not make deliberately

#### Scenario: A fresh clone reproduces the tree

- **WHEN** the remote is cloned into an empty directory on the host
- **THEN** the result evaluates the same Machine as the workstation's checkout,
  so the host is not a hand-maintained copy

### Requirement: The host runs the pinned toolchain from its own checkout

The host SHALL run the repository's pinned devenv — 2.4 or newer, the version
that provides `machines` — through `bin/devenv`, obtained from a binary cache
rather than compiled locally. The toolchain SHALL be rooted in the checkout so it
survives a garbage collection that is not otherwise prevented.

#### Scenario: The pinned version answers on the host

- **WHEN** `bin/devenv --version` is run at `/home/hbohlen/nix` on the host
- **THEN** it reports the same version as `bin/devenv --version` on the
  workstation, which is 2.4.0 or newer

#### Scenario: The toolchain is substituted, not built

- **WHEN** the pinned toolchain store path is queried against
  `https://devenv.cachix.org`
- **THEN** the path is present in that cache, so obtaining it on the host is a
  download rather than a Rust workspace build

#### Scenario: A local build does not need the workstation's store

- **WHEN** a build is run on the host while the workstation is unreachable
- **THEN** it completes, because every input it needs is in the host's own store
  or fetchable from a cache the host is configured to use

### Requirement: The host satisfies the nix preconditions a build and deploy need

The host's nix SHALL make `nix-command` and `flakes` available to a
non-interactive invocation, and the identity that runs a deploy SHALL be able to
copy to the host's store without a signature failure. The host's nix settings
SHALL be declared in this repository, not applied by hand on the live host.

#### Scenario: Flakes and nix-command are available non-interactively

- **WHEN** a nix command requiring `flakes` or `nix-command` is invoked on the
  host by a non-interactive process, with no `NIX_CONFIG` set by the caller
- **THEN** it runs, because the host's declared configuration enables both
  experimental features

#### Scenario: The deploying identity is trusted or is root

- **WHEN** the store paths a deploy copies to the host's store are read against
  the host's `trusted-users` setting
- **THEN** the copying identity is trusted, or the deploy runs as `root`, and the
  copy does not fail the trusted-signature check

#### Scenario: The settings survive a rebuild

- **WHEN** the host is rebuilt and `/etc/nix/nix.conf` is read again
- **THEN** the settings are still present, because they came from the declaration
  rather than from an edit made on the running system

### Requirement: The host holds a deploy identity for the loopback target

The host SHALL hold a private key whose public half it authorizes for `root`,
so that `root@localhost` authenticates without an agent, a password, or an
operator at a prompt. The private half SHALL live at the path the repository's
single `target.sshOpts` declaration names, so no per-invocation override is
needed, and it SHALL NOT be committed to the repository and SHALL NOT be copied
into the Nix store.

#### Scenario: Loopback root login succeeds without an agent

- **WHEN** `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i
  /home/hbohlen/.ssh/id_ed25519-op-dev` connects to `root@localhost` on the
  host, with no agent available
- **THEN** the login succeeds and reports uid 0

#### Scenario: The loopback target is a reachable nix store

- **WHEN** `nix store info --store ssh://root@localhost` is run on the host
- **THEN** it reports a usable store with a trusted connection, rather than
  failing to start the SSH connection

#### Scenario: No private key material is committed or stored

- **WHEN** the repository and the Nix store are searched for the private half of
  the loopback identity
- **THEN** only the public half appears, in the module that authorizes it

### Requirement: The SecretSpec profile resolves on the host without an interactive prompt

Every `devenv machines` invocation resolves the repository's whole SecretSpec
profile, deploy included. A `machines` command run on the host SHALL therefore
succeed without an operator typing a vault credential at a prompt, and it SHALL
resolve the same profile the workstation resolves.

#### Scenario: Inspecting the machine on the host succeeds unattended

- **WHEN** `bin/devenv machines info` is run at `/home/hbohlen/nix` on the host by
  a non-interactive process
- **THEN** it exits 0 and lists the netcup machine, rather than failing with an
  unresolvable-secret error

#### Scenario: Install-time delivery is not traded away

- **WHEN** `secretspec.toml`, `devenv.yaml`, and the Machine's `install.secrets`
  entry are read after the change
- **THEN** the manifest is still present and still declares `TS_AUTH_KEY`, so the
  property that an install enrolls the host unattended is intact

#### Scenario: No secret value is written anywhere it could be read

- **WHEN** the paths this change adds on the host, the repository and the Nix
  store are searched for secret values
- **THEN** no secret value appears in the repository, in the Nix store, or in a
  world-readable path — and the one credential the change does place on the host
  (the route 2.2 chose, design D3) is a root-owned `0600` file outside both

<!-- AMENDED 2026-09-28 during 9.1's citation pass. The scenario read "No new
     secret value is written anywhere ... in a new file the change introduced",
     which the chosen route CONTRADICTS BY CONSTRUCTION: D3 puts the SecretSpec
     credential at rest on the host at /root/.config/op-sa-token, root-owned
     0600, precisely so no interactive vault session is needed. A scenario that
     the design cannot satisfy is not evidence of a good design; the requirement
     was reworded to what the change actually promises — no secret in the tree,
     the store, or anything world-readable — which is provable (preflight gate 8,
     task 6.1's mode read-back, task 6.3's sweep of the added paths). -->

### Requirement: One Machine declaration, with the loopback target chosen per invocation

The repository SHALL declare exactly one Machine for this host. The loopback
target SHALL be selected per invocation with an option override, so that no
second, loopback-specific declaration exists to drift from the primary one.

#### Scenario: Exactly one machine is declared

- **WHEN** `bin/devenv machines info` is run in the repository root
- **THEN** the listing contains exactly one machine named `netcup`, whose
  declared target is the public address

#### Scenario: The override redirects only the invocation

- **WHEN** a `machines` command is run with the target overridden to
  `root@localhost`
- **THEN** it contacts the loopback address, and a subsequent `machines info`
  still reports the declared public target

### Requirement: A deploy run on the host rebuilds and activates the host's own system

`devenv machines deploy` run at `/home/hbohlen/nix` on the host, against the
loopback target, SHALL build the system on the host, copy it to the host's own
store, and activate it — with no second machine participating.

#### Scenario: An unchanged configuration deploys successfully

- **WHEN** a deploy of a configuration identical to the running system is run on
  the host against the loopback target
- **THEN** it completes and `machines status` reports the operation as succeeded
  rather than rolled back

#### Scenario: The activated system is the one built on the host

- **WHEN** the system the host is running after the deploy and the store path
  produced by the build on the host are compared
- **THEN** they are the same path

#### Scenario: The host's build matches the workstation's

- **WHEN** the machine is built on the host and on the workstation from the same
  revision
- **THEN** both produce a store path with the same name, so the two build
  locations are interchangeable

#### Scenario: No remote builder is required

- **WHEN** the build that precedes a host-side deploy is inspected
- **THEN** it is a native build for the host's own architecture, not one
  delegating to another machine as a builder

### Requirement: A failed self-deploy restores the previous system instead of stranding the host

When activation on a host-side deploy fails, the previous system SHALL be
restored and the failure SHALL be recorded where it can be read afterwards. A
host whose only route to recovery is the deploy that just failed is not an
acceptable outcome.

#### Scenario: A broken configuration rolls back

- **WHEN** a configuration whose activation fails is deployed from the host
- **THEN** the previously running system is restored, and the host is reachable
  and usable afterwards

#### Scenario: The outcome is readable after the fact

- **WHEN** `machines status` is run on the host after a failed deploy
- **THEN** the failure and its outcome are reported, rather than the attempt
  leaving no record

#### Scenario: The loop is recoverable without a re-image

- **WHEN** the failing configuration is corrected and deployed again from the host
- **THEN** the deploy succeeds, with no re-image of the host required

### Requirement: The loopback path does not weaken the public path, and root key-only SSH on loopback remains available

This change SHALL NOT open a port, close the public SSH path, or change the
host's firewall facts. It SHALL keep key-only root SSH available on loopback for
as long as the capability exists, which constrains any later restriction of root
login.

#### Scenario: The firewall facts are unchanged

- **WHEN** the evaluated machine's firewall facts are read after the change
- **THEN** the firewall is enabled, port 22 is the only allowed TCP port, and no
  port ranges are allowed

#### Scenario: The public path still works

- **WHEN** the operator connects to the host's public address after the change
- **THEN** the login still succeeds

#### Scenario: Root over loopback is still permitted

- **WHEN** a later change narrows the addresses from which root may log in
- **THEN** loopback is among the permitted addresses, so this capability's
  deploy path continues to work

### Requirement: The self-deploy loop is documented and its evidence is re-readable

The repository SHALL carry a procedure for the host-side loop — clone, edit,
build, deploy, verify — naming each step with the command that verifies it.
Host-touching steps are governed by `netcup-operations`' watchability
requirement, not re-declared here.

#### Scenario: The procedure names its verification

- **WHEN** the procedure document is read
- **THEN** every step names a command whose output establishes that the step
  succeeded

#### Scenario: The loop's record outlives the session

- **WHEN** a host-side deploy has finished
- **THEN** its outcome can be read again from the host's own deploy state,
  without trusting a transcript
