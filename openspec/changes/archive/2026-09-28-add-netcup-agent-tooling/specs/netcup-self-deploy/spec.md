## ADDED Requirements

### Requirement: The host declares the substituter its agent tooling is fetched from

The host's declared `nix.settings` SHALL list the binary cache the agent tooling's
packages are published to, with its public key, appended to the existing
substituters so the host continues to substitute its own closure. The declaration
SHALL be in this repository, not applied by hand on the live host.

#### Scenario: The declaration is present and additive

- **WHEN** the evaluated machine's `nix.settings.substituters` and
  `nix.settings.trusted-public-keys` are read after the change
- **THEN** the list still contains `https://cache.nixos.org` and
  `https://devenv.cachix.org`, and additionally contains
  `https://cache.numtide.com` with its `niks3.numtide.com-1:` public key

#### Scenario: An agent-tooling package substitutes rather than builds

- **WHEN** a store path the numtide cache provides (such as the `hermes-agent`
  or `herdr` output) is realized with no client-supplied substituter flags
- **THEN** it is downloaded rather than compiled from source, because the host's
  declared `nix.settings` list that cache and its key — a substituter supplied on
  the command line by a user outside `trusted-users` is silently dropped by the
  daemon (measured 2026-09-28; host `trusted-users` is `root` only)

#### Scenario: The cache declaration survives a rebuild

- **WHEN** the host is rebuilt and `/etc/nix/nix.conf` is read again
- **THEN** the numtide cache and its signing key are still listed, coming from
  the declaration rather than from a per-invocation flag
