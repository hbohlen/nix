## Context

A new root at `~/nix`. Nothing exists yet beyond `openspec/`. The previous
build at `~/projects/nixos` reached a live NixOS host, but its install path is
not reusable as-is: it needed an unhardened `nixos-anywhere` bootstrap stage, a
hardened deploy-rs stage, a tailnet enrollment, a live vault session and a
rollback timeout tuned by guesswork. Six variables, one observable outcome — a
failed install could not be attributed to any of them.

The target is the netcup VPS, currently running a throwaway OS the operator
replaces before each attempt: public IPv4 `152.53.92.126`, IPv6
`2a0a:4cc0:80:53bd::/64`, one 1 TiB virtio disk presented as `/dev/vda`, UEFI
enabled in the provider panel, 12 vCPU, 32 GiB RAM, no nested virtualization
(measured 2026-09-27 on the live host: no `/dev/kvm`, no `vmx`/`svm`).

Measured again on the current install (2026-09-27, `Ubuntu 22.04.5 LTS`,
hostname `nc`, kernel `5.15.0-194-generic`): SSH as root succeeds with the
vault identity, the disk reads `vda1` 256 MiB vfat `/boot/efi`, `vda2` 1 GiB
ext3 `/boot`, `vda3` 1022.7 GiB ext4 `/` — a layout this change deliberately
does not imitate — and the re-image replaced the host key, so a stale
`known_hosts` entry blocks the first connection until it is removed. The
tailnet is gone with the old install, which is why this change reaches the host
over its public address.

The shape of the declaration is not hypothetical: a `machines.netcup` Machine
was written and evaluated against the previous repository's own host modules on
2026-09-27 (devenv 2.4.0), producing `nixos-system-netcup-26.11pre-git`, with
the Machine's evaluated access facts (`deploy.facts`) carrying the same
`hostname`, `rootLogin` and operator-key hash as the flake host. This design
reuses the parts of that exercise that held and drops the parts that were only
there because the old repo had them.

## Goals / Non-Goals

**Goals:**

- A `machines.netcup` declaration that evaluates to a bootable NixOS system.
- A disko layout for `/dev/vda` that survives a rerun and needs no reinstall to
  grow.
- One install command against a freshly imaged target with root SSH open.
- Recorded evidence that the host booted as declared.
- Every one of those properties checkable *before* the destructive step, except
  the boot itself.

**Non-Goals:**

- Tailnet enrollment, `tailscale up`, or any overlay-network access path.
- Any secret provider: no `secretspec.toml`, no `secretspec.enable`, no vault
  contact, no `install.secrets`.
- Hardening beyond key-only SSH. Specifically not: firewall policy, root-login
  closure, fail2ban, lockdown modules. Note what the *defaults* give us anyway
  (measured through `machines.netcup.deploy.facts`): the firewall is enabled
  because that is the nixpkgs default, and port 22 is open because
  `services.openssh.openFirewall` defaults to `true`. That is not hardening
  this change chose — it is the baseline the later change starts from, and it
  must not be described as deliberate.
- Snapshots, zram or swap, disk encryption, container storage, per-project or
  agent-workspace subvolumes, and any operator tooling on the host.
- The `oci` host, and any second machine.

## Decisions

**D1 — Declare the host as a devenv Machine, not as a flake `nixosConfigurations`
entry.** A Machine puts the host configuration and the operator environment in
one file with two consumers (`devenv shell`, `devenv machines …`), which is the
whole point of the direction. *Alternative:* the previous arrangement (flake +
`lib/mkHost.nix` + deploy-rs) — rejected here because it costs a second tool to
reach the same first boot, and because Machines' install collapses the bootstrap
stage the old path needed. *Consequence accepted:* a host-assembly wrapper
cannot run at all; devenv builds the module list itself
(`{ nixpkgs.hostPlatform }`, `disko.nixosModules.disko`, devenv's internal
`recovery.nix` and `facts.nix`, then our `nixos` module).

**D2 — devenv 2.4.x, with the lock's `devenv` input at the same revision.**
`machines` does not exist in 2.3.1, which is what nixpkgs currently ships.
Measured 2026-09-27: `nix build github:cachix/devenv/v2.4.0#devenv` substitutes
from `devenv.cachix.org` in seconds (with the cache added as an extra
substituter), whereas building the flake without that cache compiles the Rust
workspace from source for tens of minutes. *Alternative:* build from nixpkgs —
rejected, no `machines` subcommand. *Trap recorded:* the 2.4 binary against a
lock still pinned to an older `devenv` input fails with
`Failed to get attribute 'devenv.config.machinesMeta'`; both must be bumped
together. The opt-in flow is: `nix shell` the 2.4 binary, then `devenv update`.

**D3 — `hardware.facter = null`, with an explicit hardware module.** The host's
hardware facts need no generated report: disko derives every `fileSystems`
entry, and the only kernel-side facts are VirtIO initrd modules, which come
from an explicit module. This also keeps `nixos-facter-modules` out of the
input graph. *Alternative:* the facter default (`.machines/netcup/facter.json`)
— rejected for this milestone: a generated report is a moving part whose absence
breaks evaluation, and it changes the config from declared to measured.

**D4 — disko layout: one disk, one 1 GiB ESP at `/boot`, one `100%` btrfs root,
subvolumes `@`, `@home`, `@nix`, `@var`.** The ESP is a single vfat partition at
`/boot` rather than the fresh OS's ESP-plus-`/boot` split, because systemd-boot
reads kernels from the ESP and a second ext4 `/boot` is one more thing that can
disagree. `@nix` and `@var` are separate subvolumes even though nothing uses
them yet: adding them later means a reinstall or an offline resize, which is
exactly the failure mode subvolumes exist to avoid. *Alternatives:* a single `@`
with no subvolumes — rejected as the reinstall trap; the previous build's
nine-subvolume set — rejected as speculative for this milestone. No LUKS and no
swap, both explicitly deferred (spec'd as shall-not requirements so neither
appears by accident).

**D5 — Root SSH stays open, key-only, for this milestone.** `devenv machines
install` and `deploy` require root SSH; a configuration that closes it cannot be
installed by the tool at all. Measured on the previous repository's config:
`deploy.facts.ssh.rootLogin = "no"` and `installCheck.hasRootAuth = false` —
i.e. that host was installable by `nixos-anywhere` and not by Machines. So this
build authorizes the operator's ed25519 key for root and for the operator
account, and disables password authentication for both. *Alternative:*
user-only SSH + `sudo` — not available, the installer needs root; *alternative:*
a temporary root key removed after install — rejected for this milestone
because it would make the *next* deploy fail for a reason unrelated to the
install. The hardening change that closes root login must therefore decide what
replaces the deploy path; that is recorded as an open question, not silently
deferred.

**D6 — No `secretspec.toml` and no `secretspec.enable` in this build.**
Measured 2026-09-27: with a manifest present, *every* `devenv machines`
invocation resolves the whole profile — a read-only `devenv machines info`
refused to run until all six declared secrets were resolvable. Keeping the
manifest absent keeps the install path free of a provider by construction
rather than by discipline.

**D7 — Accept devenv's nixpkgs, and say so.** A Machine builds against
`devenv.yaml`'s `inputs.nixpkgs` (devenv-nixpkgs/rolling), not against any flake
pin. Measured: the same module tree evaluated to `26.11pre-git` under devenv
while the flake host was `26.05.20260914.c3eea5b`. *Alternative:* pin
`nixos-26.05` in `devenv.yaml` — rejected for this milestone because devenv's
own package set is built against its fork, and a host that evaluates but cannot
build is worse than a host one release ahead. `system.stateVersion` is set
explicitly and read from the Machine's own nixpkgs at first eval.

**D8 — The install targets the public IPv4.** No overlay network is in scope, so
`target.host` is the public address and the pre-flight proves it is the intended
host before anything is written. The tailnet change rewrites this one line.

**D9 — No `nixpkgs.config` anywhere in this build.** A module may not set
`nixpkgs.config` for a Machine: devenv creates the pkgs instance outside the
module system (`pkgs = inputs.nixpkgs.legacyPackages.<system>`) and evaluation
fails with "Your system configures nixpkgs with an externally created
instance". The previous repository's shared baseline hit exactly this on
`allowUnfree`. This build declares no unfree packages, so the constraint costs
nothing here — and holding that line is cheaper than the `mkForce { }` +
`allow_unfree: true` workaround it needed.

**D10 — The host identity is the 1Password `dev` vault SSH item.** The vault
holds an ed25519 key `SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ`;
the workstation's own `~/.ssh/id_ed25519` is a different key
(`SHA256:DnpZNFSTyvWafuCRJzJBhOD7KCU9SWj61tsGOSXQldA`). The vault key is the
identity, and it is already installed as the only entry in the re-imaged
target's `/root/.ssh/authorized_keys` — measured 2026-09-27: root login
accepted it (`Accepted publickey for root … SHA256:HvoLYt+…`). *Alternative:*
keep the workstation key, as the previous build did — rejected because the
operator's canonical identity now lives in the vault and the throwaway OS
already trusts it, so using anything else adds a key-distribution step to the
one procedure this milestone exists to isolate. The private half is
materialized per use with `op inject` into a `0600` file; it is never an
environment variable, never in the repository, never in the Nix store. Note the
injected value arrives **without a trailing newline** and `ssh-keygen` reports
`invalid format` until one is appended.

## Risks / Trade-offs

- **[The install is irreversible and has no dry run]** — disko partitions and
  formats without prompting; `devenv machines install` offers no rehearsal and
  only `--phases` resumes an interrupted run → the four pre-flight gates are
  mandatory and recorded, and the recovery path is re-imaging the target, which
  requires no state from the failed attempt.
- **[The layout assumes `/dev/vda`]** — a target presenting its disk under a
  different name would partition the wrong device → the pre-flight asserts the
  boot disk's device path before the install, and the layout declares exactly
  one device so a mismatch cannot silently target a second disk.
- **[UEFI first boot can fail with no console attached]** — VPS NVRAM writes are
  unreliable → `canTouchEfiVariables = false`, systemd-boot with an explicit
  boot entry, and the provider console as the recovery path; boot success is
  itself the last gate rather than an assumption.
- **[Root SSH is open for the whole window between install and the hardening
  change]** — exposure is bounded by key-only authentication, password auth
  disabled, and the operator key being the only authorized one → accepted for
  this milestone; the hardening change must close it and must also solve the
  deploy path it closes.
- **[devenv Machines is experimental in 2.4]** — `install` is the least
  exercised subcommand and the docs' own steadiest claim about it is that it
  partitions without prompting → this milestone deliberately has no other
  moving part, so a failure is attributable; if Machines' install proves
  unreliable, the disko layout and the module tree survive it, and only the
  command changes.
- **[No swap]** — 32 GiB is enough for a host running nothing, but Nix builds on
  the host can spike → accepted; the change that puts workloads on the host
  measures memory first, rather than inheriting a swap decision.
- **[devenv-nixpkgs rolling drifts under a stateful host]** — the host's
  `system.stateVersion` is pinned, so stateful defaults do not migrate, but the
  package set will move on every `devenv update` → accepted deliberately;
  version pinning is a decision for the change that needs it, and pinning here
  would fight devenv's own inputs.
- **[The operator workstation's ambient SSH config is broken]** — every `ssh`
  invocation aborts with `Invalid environment expansion
  ${XDG_RUNTIME_DIR}/ssh-agent.socket` when `XDG_RUNTIME_DIR` is unset, which is
  every non-interactive context, and it targets a tailnet name that no longer
  exists → not this change's to fix; the install run must bypass it explicitly
  (an `-F /dev/null` style invocation with the key pinned) rather than inherit
  it, or an agent-driven install fails before it reaches the target.

## Migration Plan

There is nothing to migrate: a new root, and a target whose current OS is
discarded. The sequence is *pre-flight → install → verify*, and the rollback
strategy is re-imaging the target.

1. Confirm the target is a fresh OS with root SSH open, and run the four
   pre-flight checks; record their output.
2. Run the single install command.
3. Run the post-install evidence commands and compare against the specs'
   scenarios.
4. On failure at any point after the first write: re-image the target and start
   from step 1. No cleanup on the failed host.

## Gates

Every requirement maps to a check that a reviewer can run; the ones marked
*post-install* are the boot-dependent residual.

| Requirement | Proof |
|---|---|
| Machine is enumerable | `devenv machines info` lists `netcup`, role `nixos` |
| System evaluates | `devenv eval machines.netcup.build.nixos` → `nixos-system-netcup-*` |
| No secret provider at eval | same eval with no vault session and no manifest |
| Explicit `system.stateVersion` | `devenv eval` of the config attribute |
| No facter dependency | `devenv.yaml` input list + `hardware.facter` attribute |
| UEFI boot *(post-install)* | host answers SSH after reboot; `bootctl status` |
| Key-only SSH *(post-install)* | key login succeeds; password login refused |
| One disk, `/dev/vda` | evaluated `disko.devices.disk` |
| ESP 1 GiB at `/boot`, restrictive | evaluated ESP content + bootloader mountpoint |
| Root `100%` btrfs, two partitions | evaluated partition sizes/content |
| Subvolume set and options | evaluated subvolumes: names, mountpoints, options |
| No swap, no encryption | evaluated `disko.devices` + `swapDevices` |
| Preconditions gated | recorded pre-flight output; no write on a failed gate |
| Single command, no bootstrap | repository contains no bootstrap target, no deploy node |
| No vault, no tailnet during install | absence of manifest + recorded public-address run |
| Install evidence *(post-install)* | `nixos-version`, mounted subvolumes, key SSH login |
| Recovery needs no host state | re-image and rerun; no host-side cleanup step |
| Procedure documented | the repository's install document |

## Open Questions

- **What replaces the deploy path when root login closes?** Machines' `deploy`
  needs root SSH. Closing root login therefore also closes routine deploys. The
  options (a key-holding root confined to the tailnet, a dedicated deploy
  account the installer accepts, or keeping root-key SSH permanently) are a
  decision for the hardening change, but the install change is what creates the
  debt, so it must be named now.
- **Which release string does `system.stateVersion` get?** It must match the
  Machine's own nixpkgs (devenv-nixpkgs/rolling), not a remembered release.
  Read it from the first successful eval rather than guessing.
- **Is a 1 GiB ESP the right size?** systemd-boot stores kernels there and the
  previous build chose 1 GiB with a 10-generation limit. Nothing in this
  milestone depends on the number; it is cheap to change before the first
  install and expensive after.
- **Does the freshly imaged OS's installer leave an EFI variable that changes
  the boot order?** If the first boot lands in the provider's UEFI shell rather
  than systemd-boot, that is a console-side fix discovered at the boot gate —
  worth knowing before the window opens.
- **Does `devenv machines install` accept a target whose only access is public
  IPv4 with root SSH?** Half-answered 2026-09-27: root SSH over the public
  address is measured green with the vault identity, so the access shape is
  proven and only the install command itself remains unmeasured. The pre-flight
  proves root SSH works; the install is the measurement.
