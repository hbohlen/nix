## Why

The previous netcup build never got a settled install path. Reaching a first
boot required an unhardened `nixos-anywhere` bootstrap stage, a hardened
deploy-rs stage, a tailnet enrollment, a vault session and a rollback timeout
tuned by guesswork — so when the install failed there was no way to tell which
of those six things was responsible. This change reduces the first install to
the two things that cannot be deferred — the disk layout and the install
procedure — and removes every other variable from the path. A host that boots
and answers SSH from a `devenv machines install` is the whole deliverable.

This is also the first change in a new root (`~/nix`). It establishes what a
minimal Machine looks like before anything is layered onto it.

**Milestone advanced:** netcup boots NixOS from a declarative disko layout,
installed by `devenv machines install`, and is reachable over SSH.

## What Changes

- **New:** a `machines.netcup` declaration in `devenv.nix` that evaluates to a
  bootable NixOS system for the netcup VPS (x86_64-linux).
- **New:** a disko layout for the host's single virtio boot disk — GPT, one ESP,
  one btrfs root partition carrying a minimal subvolume set.
- **New:** `devenv.yaml` inputs for nixpkgs and disko. disko is mandatory for any
  NixOS Machine; the input must use devenv.yaml's nested `inputs.<name>.follows`
  form, since the flat form silently locks the input as an alias of nixpkgs.
- **New:** a minimal base NixOS configuration — hostname, one operator account
  with an authorized key, sshd reachable on the public interface, UEFI boot.
- **New:** an install procedure with pre-flight gates that run before the one
  irreversible command, and post-install verification that runs after reboot.
- **Not in this change:** tailnet enrollment, any secret provider (no
  `secretspec` manifest, no `secretspec.enable`), snapshot scheduling, zram or
  swap, disk encryption, agent tooling, and any hardening beyond key-only SSH.
  Each is a later change that adds exactly one variable.
- **Dropped relative to `~/projects/nixos`:** the `lib/mkHost.nix` variant gate
  and `hosts/netcup/bootstrap.nix` (Machines builds the module list itself, so
  the two-stage split has nothing to attach to), the `deploy.nodes.netcup`
  deploy-rs node, and the Proton Pass `secretspec.toml`.
- **Contradicts `~/projects/nixos`:** ADR-0001's devenv/host boundary (a Machine
  puts both in one file), ADR-0003's zram decision (no swap yet — not a
  re-decision, a deferral), and ADR-0005's operator-workstation premise (the
  workstation is `contabo`; netcup is a target, not the operator's machine).

## Capabilities

### New Capabilities

- `netcup-machine`: The devenv Machine declaration for netcup and the minimal
  NixOS configuration it evaluates to — the interface a later change extends.
- `netcup-disk-layout`: The declarative disk layout applied to the host's boot
  disk, and the safety property that it only ever targets that disk.
- `netcup-install`: The install procedure — its preconditions, the single
  irreversible step, and the evidence that the host came up.

### Modified Capabilities

- None. This root has no existing specs.

## Impact

- **Repository:** new root `~/nix`. Files introduced: `devenv.nix`,
  `devenv.yaml`, `devenv.lock`, `hosts/netcup/{default,disko,hardware}.nix`.
  No existing specs or capabilities are touched (none exist).
- **Toolchain:** devenv 2.4 or newer (the `machines` CLI does not exist in
  2.3.1, which is what nixpkgs currently ships), plus `disko` as a devenv input.
- **Target:** the netcup VPS — public IPv4 `152.53.92.126`, IPv6
  `2a0a:4cc0:80:53bd::/64`, one 1 TiB virtio disk presented as `/dev/vda`,
  UEFI enabled in the provider panel, 12 vCPU / 32 GiB RAM, no nested
  virtualization. The operator replaces the current OS with a fresh
  Debian/Ubuntu that accepts root SSH before the install runs.
- **Authentication:** the operator's existing ed25519 key
  (`SHA256:DnpZNFSTyvWafuCRJzJBhOD7KCU9SWj61tsGOSXQldA`, comment
  `hbohlen-vast.ai`) is the only key authorized by this configuration. Its
  public half goes in the module; its private half never leaves the
  workstation, and no vault is contacted.
- **DESTRUCTIVE:** `disko` partitions and formats without prompting, and
  `devenv machines install` has no dry run. The pre-flight gates in
  `netcup-install` exist specifically because the irreversible step cannot be
  rehearsed.
- **Pre-existing, not this change's:** the ambient SSH configuration on the
  operator workstation (`~/projects/nixos/deploy/ssh-config.netcup`, included
  from `~/.ssh/config`) aborts every `ssh` invocation with
  `Invalid environment expansion ${XDG_RUNTIME_DIR}/ssh-agent.socket` wherever
  `XDG_RUNTIME_DIR` is unset, which is every non-interactive context. It also
  targets `netcup.worm-hue.ts.net`, a name that no longer exists in the tailnet
  (the node is now `nc`). This change does not depend on that file, but an
  agent-driven install must not inherit it.
