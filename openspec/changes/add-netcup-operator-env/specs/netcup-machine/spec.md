## MODIFIED Requirements

### Requirement: The netcup host is declared as a devenv Machine

The repository SHALL declare the netcup host as `machines.netcup` in
`devenv.nix`, with `system = "x86_64-linux"` and a `target.host` naming the
address the installer connects to. The declaration SHALL be the only surface
that defines this host's NixOS configuration.

#### Scenario: The Machine is enumerable

- **WHEN** the operator runs `devenv machines info` in the repository root
- **THEN** the listing contains a machine named `netcup` with system
  `x86_64-linux` and roles `nixos` and `home-manager` — both roles on the one
  declaration, since `add-netcup-operator-env` carries the operator environment
  as a home-manager role

#### Scenario: No competing host-definition surface exists

- **WHEN** the repository is inspected for a `flake.nix` exporting
  `nixosConfigurations.netcup`, and for a host-assembly function such as
  `lib/mkHost.nix`
- **THEN** neither exists, because devenv builds a Machine's module list itself
  and would never call such a function
