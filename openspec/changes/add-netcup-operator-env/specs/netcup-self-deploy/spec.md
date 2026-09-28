## MODIFIED Requirements

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

#### Scenario: A non-root build substitutes from a cache the host declares

- **WHEN** the operator account realizes a store path that
  `https://devenv.cachix.org` provides, with no client-supplied substituter
  flags
- **THEN** it is downloaded rather than built from source, because the host's
  declared `nix.settings` list that cache and its key — a substituter supplied
  on the command line by a user outside `trusted-users` is silently dropped by
  the daemon (measured 2026-09-28, workstation nix 2.34.7; host nix 2.34.8)

#### Scenario: The cache declaration survives a rebuild

- **WHEN** the host is rebuilt and `/etc/nix/nix.conf` is read again
- **THEN** the cache and its signing key are still listed, coming from the
  declaration rather than from a per-invocation flag

### Requirement: A failed self-deploy restores the previous system instead of stranding the host

When activation of the system role on a host-side deploy fails, the previous
system SHALL be restored and the failure SHALL be recorded where it can be read
afterwards. A host whose only route to recovery is the deploy that just failed is
not an acceptable outcome.

The home-manager role is a separate activation with no rollback of its own: when
it fails after the system role has succeeded, the applied system SHALL NOT be
reverted, the failure SHALL be recorded by the same means, and recovery SHALL be
by correcting the role and deploying again — never requiring a re-image.

#### Scenario: A broken configuration rolls back

- **WHEN** a configuration whose system activation fails is deployed from the
  host
- **THEN** the previously running system is restored, and the host is reachable
  and usable afterwards

#### Scenario: The outcome is readable after the fact

- **WHEN** `machines status` is run on the host after a failed deploy
- **THEN** the failure and its outcome are reported, rather than the attempt
  leaving no record

#### Scenario: The loop is recoverable without a re-image

- **WHEN** the failing configuration is corrected and deployed again from the host
- **THEN** the deploy succeeds, with no re-image of the host required

#### Scenario: A home-manager failure leaves the applied system in place

- **WHEN** a deploy whose system role succeeds fails during the home-manager
  activation
- **THEN** the new system generation remains active rather than being rolled
  back, `machines status` reports the failure, and correcting the role and
  deploying again succeeds with no re-image
