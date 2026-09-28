## MODIFIED Requirements

### Requirement: The SecretSpec profile resolves on the host without an interactive prompt

Every `devenv machines` invocation resolves the repository's whole SecretSpec
profile, deploy included. A `machines` command run on the host SHALL therefore
succeed without an operator typing a vault credential at a prompt, and it SHALL
resolve the same profile the workstation resolves. The identity that runs a
host-side deploy is `root`, so root's credential SHALL remain present and
readable by root; the operator account's credential is an additional holder and
SHALL NOT be depended on by the loop.

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
  world-readable path — and the credentials the change places on the host
  (root's loop credential and the operator's) are `0600` files outside both

#### Scenario: The deploying identity's credential is not the operator's

- **WHEN** a host-side deploy runs after the operator account has gained its
  own credential
- **THEN** the loop still resolves the profile using root's credential, so a
  change to the operator's credential cannot break the loop

<!-- AMENDED 2026-09-28 during 9.1's citation pass. The scenario read "No new
     secret value is written anywhere ... in a new file the change introduced",
     which the chosen route CONTRADICTS BY CONSTRUCTION: D3 puts the SecretSpec
     credential at rest on the host at /root/.config/op-sa-token, root-owned
     0600, precisely so no interactive vault session is needed. A scenario that
     the design cannot satisfy is not evidence of a good design; the requirement
     was reworded to what the change actually promises — no secret in the tree,
     the store, or anything world-readable — which is provable (preflight gate 8,
     task 6.1's mode read-back, task 6.3's sweep of the added paths). -->
