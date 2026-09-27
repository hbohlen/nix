## ADDED Requirements

### Requirement: The tailnet node name is declared, not inherited

The netcup configuration SHALL pin the Tailscale node name to `nc`, so that the
node's MagicDNS name is `nc.worm-hue.ts.net` independently of the host's own
`networking.hostName`. The host's `networking.hostName` SHALL remain `netcup`.

#### Scenario: The node name is pinned in the configuration

- **WHEN** the built system's generated
  `etc/systemd/system/tailscaled-autoconnect.service` is read
- **THEN** its `tailscale up` command line contains `--hostname=nc`

#### Scenario: The host's own hostname is untouched

- **WHEN** the built system's `etc/hostname` is read
- **THEN** it is `netcup`

#### Scenario: The overlay presents the pinned name

- **WHEN** the operator runs `tailscale status --json` on any tailnet member
  after enrollment
- **THEN** the peer list contains exactly one node whose `DNSName` is
  `nc.worm-hue.ts.net.`

### Requirement: The host enrolls from its own configuration

The configuration SHALL set `services.tailscale.authKeyFile` to an absolute
host path and SHALL deliver the auth key to that same path through
`install.secrets`, so that an installed host reaches the tailnet unattended on
its first boot. Enrollment SHALL NOT depend on an operator running
`tailscale up` by hand.

#### Scenario: The key path is a string, not a store path

- **WHEN** the built system's generated `tailscaled-autoconnect.service` is read
- **THEN** it names `authKeyFile` as a plain absolute path, and no member of the
  machine's derivation closure contains the auth key value

#### Scenario: The delivering path and the reading path are the same

- **WHEN** the absolute path in `machines.netcup.install.secrets` and the value
  of `services.tailscale.authKeyFile` are compared
- **THEN** they are identical, and the secret named there is `TS_AUTH_KEY`

#### Scenario: The delivered file is root-only

- **WHEN** the `install.secrets` entry for the auth key is read
- **THEN** its `mode` is `0600` and its `owner` is `0:0`

#### Scenario: The enrollment unit is generated

- **WHEN** the evaluated system's systemd units are inspected
- **THEN** `tailscaled-autoconnect.service` exists and is wanted by
  `multi-user.target`, because `authKeyFile` is set

#### Scenario: The absent-key state does not abort a deploy

- **WHEN** the built system's generated `tailscaled-autoconnect.service` is read
- **THEN** it carries `ConditionPathExists` for the path named by
  `authKeyFile`
- **AND** on a host where that path does not exist yet the unit is *skipped*
  rather than failed (`ConditionResult=no`, not `Result=failure`), so
  `switch-to-configuration` completes and the deployment is not rolled back

#### Scenario: A live host reaches the same state without a re-image

- **WHEN** the declared key path is populated on an already-installed host and
  `tailscaled-autoconnect.service` is started
- **THEN** the host enrolls through the same unit an install would rely on, with
  no re-image and without an operator typing a `tailscale up` command

### Requirement: No auth key value is stored in the repository or the Nix store

The repository SHALL hold only the declaration of the secret — its name and the
vault item it reads — and SHALL NOT contain the auth key's value. The Nix store
SHALL NOT contain the value.

#### Scenario: The manifest declares without holding

- **WHEN** `secretspec.toml` is read
- **THEN** it names the secret, its description, and the `dev` vault item, and
  contains no key material

#### Scenario: The value is not in the store

- **WHEN** the store paths reachable from the Machine's derivation closure are
  searched for the auth key value
- **THEN** no match is found

#### Scenario: The value never leaves the vault except into the declared file

- **WHEN** the auth key is read, it is read through SecretSpec or the vault CLI
  directly into the declared host path
- **THEN** it is never printed to a terminal, never passed as a command-line
  argument, and never stored anywhere but that path

### Requirement: Exactly one node named nc exists in the tailnet

The change SHALL leave the tailnet holding one node named `nc`. A node created
by a previous install of the same host SHALL be removed rather than left
alongside the new one.

#### Scenario: The stale node is gone before enrollment

- **WHEN** the operator runs `tailscale status` from the workstation before
  enrolling the host
- **THEN** no peer named `nc` is listed

#### Scenario: The new node takes the unsuffixed name

- **WHEN** the host has enrolled
- **THEN** its node name is `nc`, not a deduplicated variant such as `nc-1`

#### Scenario: The node carries the tailnet's tag

- **WHEN** the enrolled node's tags are read from `tailscale status --json`
- **THEN** it carries `tag:server`, matching every other node in this tailnet

### Requirement: The host is reachable over the overlay without weakening the public path

With the tailnet up, the host SHALL be reachable over the overlay by its
MagicDNS name using the same key-only SSH identity as the public path. The
public path SHALL remain available and unchanged by this change.

#### Scenario: The node reports online

- **WHEN** the operator runs `tailscale status` after the host has enrolled
- **THEN** the `nc` node is listed as online with a `100.64.0.0/10` address

#### Scenario: SSH over the overlay succeeds

- **WHEN** the operator connects to `nc.worm-hue.ts.net` as the operator account
  with the vault identity
- **THEN** the login succeeds

#### Scenario: The public path is unaffected

- **WHEN** the operator connects to `152.53.92.126` as the operator account
  after the change
- **THEN** the login still succeeds, and the evaluated firewall facts still show
  the firewall enabled with port 22 as the only allowed TCP port and no allowed
  port ranges

#### Scenario: Unattended re-enrollment survives a reboot

- **WHEN** the enrolled host is rebooted
- **THEN** `tailscaled-autoconnect.service` exits successfully without sending
  the auth key again, because the node's state is already `Running`
