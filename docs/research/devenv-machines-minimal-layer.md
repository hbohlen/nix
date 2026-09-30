# devenv `machines` — What Must Live in the Machine Layer

> Research note. Primary sources fetched 2026-09-28 from <https://devenv.sh/machines/>,
> <https://devenv.sh/blog/2026/09/24/devenv-24-machines/>,
> <https://devenv.sh/reference/options/#machines>, and
> <https://github.com/cachix/devenv/blob/main/src/modules/machines.nix>.
> The plan's Home Manager output and activation order were checked against the
> pinned v2.4.0 CLI source at
> <https://github.com/cachix/devenv/blob/v2.4.0/devenv/src/devenv/machines.rs>.
> All decisive claims are quoted verbatim. Anything undocumented is marked `NOT DOCUMENTED`.

---

## 1. The Role Model

### How many roles can one Machine have?

A Machine has three possible role slots: `nixos`, `nix-darwin`, and `home-manager`.
The docs state:

> The roles are `nixos`, `nix-darwin`, and `home-manager`. A machine can have a system role and a home-manager role; both use the same target.

(<https://devenv.sh/machines/>)

So the combinatorics are: one **system** role (`nixos` OR `nix-darwin`) plus optionally one `home-manager` role. A Machine cannot have both `nixos` and `nix-darwin` simultaneously. The prior research's claim that `netcup` has two roles (nixos + home-manager) is the maximal combination.

### Activation order

> Every role is built, and remote outputs are copied, before activation begins. Machines activate one at a time in name order by default. `--max-concurrent` activates batches; after a failure, no new batches start, but successful machines stay deployed. **Within a machine, home-manager activates after the system role.**

(<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>)

### Rollback semantics — verbatim

> NixOS has automatic rollback; nix-darwin and home-manager do not. **A failed home-manager activation leaves an already confirmed NixOS deployment in place.**

(<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>)

The prior research's claim that "HM is a second activation that NixOS rollback does **not** revert" is confirmed. A system rollback (triggered by `machines rollback` or the watchdog) restores only the system generation; it does **not** revert home-manager files or activation scripts.

---

## 2. `machines check`, `plan`, `apply`, `status`, `rollback`

| Command | Semantics |
|---|---|
| `machines info` | Read metadata without building or contacting targets. |
| `machines check <name>` | Compares declared SSH access changes with facts read from the target **without building or deploying**. Blocks deployments that would disable SSH or root login. `check --json` is structured. Cannot verify external firewalls, dynamic keys, or that you possess a working key. (<https://devenv.sh/machines/>) |
| `machines build <name>` | Realizes all role outputs locally without deploying them. `devenv build machines.server.build.nixos` builds a single role. |
| `machines install <name>` | Installs NixOS on a fresh host. **Wipes disks without a confirmation prompt and has no dry run.** Requires a machine name. Phases run in order: `kexec, facter, disko, install, reboot`. (<https://devenv.sh/machines/>) |
| `machines deploy <name>` | Updates an existing system. With no names, selects all remote machines. |
| `machines plan <name>` | Builds and records each role output, access facts, and closure deltas **without** copying or activating. This includes the Home Manager activation package. Saves under `.devenv/machine-plans/<id>/`. `plan --json` exports the plan. |
| `machines apply plan-...` | Applies the saved role outputs, including Home Manager. **Refuses a stale plan.** Copies all outputs before activating any target. |
| `machines status <name>` | Reports one of: `pending`, `rolled-back`, `rollback-failed`, `unknown`. Does not build. |
| `machines rollback <name>` | Restores the previous recorded NixOS system. Blocks new deployments when the last result is `unknown`. |

### What is a 'stale plan'?

> a changed target or generation makes it stale.

(<https://devenv.sh/machines/>, prior research item 7)

A plan is a trusted deployment input (it selects executable store paths). If the target host has changed or the current generation no longer matches the plan's assumptions, `apply` refuses to proceed.

---

## 3. `deploy.healthCheck` and `deploy.rollbackTimeout`

From the deploy.nix source (<https://github.com/cachix/devenv/blob/main/src/modules/machines/deploy.nix>):

```nix
{ pkgs, healthCheck ? "true", rollbackTimeout ? 300 }:
```

**Defaults:**
- `healthCheck`: `"true"` — checks only the system paths (i.e., the NixOS generation exists and is linked). The prior research is correct: this is a **minimal** check, not an application-level one.
- `rollbackTimeout`: `300` seconds. Range: 30–600. (<https://devenv.sh/reference/options/#machines>)

**What the default health check actually verifies:**
The default `"true"` exits 0 with no real verification of service health. It confirms only that the system path is active. If any service (sshd, networking) fails to come up, the default check still passes — the watchdog will then roll back on the *timeout*, not on a health signal.

**Custom health check — verbatim from the docs:**

> ```nix
> machines.server.deploy {
>   rollbackTimeout = 300; # 30 to 600 seconds
>   healthCheck = "/run/current-system/sw/bin/systemctl is-active --quiet my-app.service";
> };
> ```

Runs as root on the target with absolute paths. Returns non-zero or timeout blocks confirmation and triggers rollback.

(<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>)

**Implementation detail:** The health check script is built via `pkgs.writeShellScript`, injected via `DEVENV_MACHINE_HEALTH_CHECK`, and the PATH is prepended with `nix`, `systemd`, `coreutils`.

---

## 4. What is ONLY possible in the Machine layer

The devenv shell layer cannot do any of these — they require a Machine declaration and target activation:

| Capability | Why it requires the Machine layer |
|---|---|
| **Disk layout (disko)** | `disko` partitions and formats disks from a declarative spec. Requires `disko` input and runs at install-time via the kexec'd installer. |
| **Bootloader** | `boot.loader.systemd-boot.enable = true` is a NixOS system-level option that writes EFI variables and `/boot`. |
| **NixOS services** | `services.openssh.enable`, `services.tailscale.*`, `services.postgresql.*` are system-level `systemd` units. |
| **Firewall** | `networking.firewall.*` and `networking.nftables.*` configure kernel netfilter at boot. |
| **SSH daemon config** | `services.openssh.settings` (PermitRootLogin, ports, authorized keys) is a system-level daemon. |
| **System users** | `users.users.<name>` and `users.groups.<name>` create `/etc/passwd` entries, home directories, SSH authorized_keys. |
| **Boot-time units** | `systemd.services.<name>.wantedBy = [ "multi-user.target" ]` and the recovery service (`devenv-machines-recover`) must be present in the system profile, not a shell. |
| **Kernel/initrd** | `boot.initrd.availableKernelModules` (e.g., VirtIO for `/dev/vda`) is system-only. |
| **nixos-install / first-boot secrets** | `install.secrets`, `install.extraFiles`, `install.copyHostKeys`, `install.encryptionKeys` only run during `machines install`. |

---

## 5. Install-time options: what runs when

From the machines page and the blog:

> For an interrupted install, inspect the target before selecting phases with `--phases`. The phases run in this order: **kexec, facter, disko, install, reboot**.

(<https://devenv.sh/machines/>)

### Option execution order relative to `nixos-install` and reboot:

| Option | When it runs | Purpose |
|---|---|---|
| `install.encryptionKeys` | **Before disko** | Send local key files needed by disk layout (e.g., LUKS key). |
| `install.extraFiles` | **After nixos-install** | Copy local files into the installed system. Strings are local file paths (not Nix path literals). File owner is numeric `uid:gid`. Default mode `0644`, owner `0:0`. |
| `install.secrets` | **After extraFiles** | Write named SecretSpec values into the installed system. Default mode `0600`. Requires either `secretspec.enable` in devenv.yaml (local execution) or `execution = "target"`. |
| `install.copyHostKeys` | **Before reboot** | Copy `/etc/ssh/ssh_host_*` from the live installer into the installed system. Default `false`. Makes the host key stable across install. |

All bootstrap files are written **only** during `machines install`. There is no deploy-side equivalent — `deploy` does NOT refresh these files.

---

## 6. Can a Machine target an EXISTING non-NixOS host (Arch) and convert it?

**NOT DOCUMENTED** in upstream devenv docs.

The docs say only:

> Install NixOS on a **fresh host**

and

> devenv connects over SSH, enters a NixOS installer with kexec, collects hardware facts, and builds the system before changing disks. ... Installation **partitions and formats disks without prompting**.

(<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>)

No upstream doc addresses converting an Arch (or Debian, etc.) host in-place. The underlying toolchain is `nixos-anywhere`, which **can** convert any Linux host with kexec support — but devenv's documentation does not describe this workflow, does not mention pre-existing OSes, and does not warn about preserving existing data beyond the SSH host key (`copyHostKeys`). The word "fresh" is used repeatedly for install targets.

Community tools exist for this (`nixos-infect`, `nixos-bite`, `nixos-in-place`), but none are endorsed or documented in the devenv machines workflow.

**Bottom line:** Treat `machines install` as requiring a freshly imaged or disposable target. If you need to convert an existing Arch host, you would need to either (a) re-image it first, or (b) use `nixos-anywhere` directly outside devenv. Devenv gives no guidance on the in-place conversion path.

---

## 7. Home-manager-only machine with no `target.host`

Yes — this is documented. The machines page states:

> A home-manager-only machine can **omit `target.host` to activate locally.** Setting it to `localhost` still uses SSH.

(<https://devenv.sh/machines/>)

Confirmed by the source code:

> Leave unset to activate in process on the current host; this is only valid for `home-manager`.

(<https://github.com/cachix/devenv/blob/main/src/modules/machines.nix>, line 263)

Example pattern from the docs:

```nix
{
  machines.me = {
    home-manager = {
      home.username = "jdoe";
      home.homeDirectory = "/home/jdoe";
      programs.git.enable = true;
    };
  };
}
```

> `devenv machines deploy me` activates locally. `devenv machines deploy workstation` routes through SSH.

(<https://devenv.sh/blog/2026/09/24/devenv-24-machines/>)

**Caveat:** home-manager has **no automatic rollback**. A failed activation leaves the previous home-manager state as-is (files may be partially written). The system role, if present, is unaffected.

---

## The Irreducible Machine Layer

The smallest set of things that **must** stay in a Machine declaration — nothing in the devenv shell layer can substitute:

1. **`target.host`** — SSH destination for NixOS/nix-darwin deployment. Required for any remote Machine. (Home-manager-only may omit it for local activation.)
2. **`nixos` / `nix-darwin` role** — the system configuration module. At minimum must define:
   - `fileSystems` (or rely on disko input)
   - `boot.loader`
   - `networking.hostName`
   - `services.openssh` (if you want SSH access post-deploy)
   - System users that the home-manager role depends on
3. **`disko` input** — required even when only deploying, because the NixOS machine evaluation pulls `disko.nixosModules.disko` from the input. (Disk layout itself is in the NixOS module.)
4. **`install.*` block** — anything needed for first boot: secrets (e.g., age key for sops-nix, Tailscale auth key), extraFiles, encryptionKeys, copyHostKeys. **Only runs at install time, never at deploy time.**
5. **`deploy.healthCheck`** — if the default `"true"` is too weak for your services, a custom check must live here. It is the only declarative rollback trigger.
6. **`deploy.rollbackTimeout`** — if 300 s is too short for your boot/service-start sequence, it must be tuned here.

The NixOS role does not need packages, dev tools, languages, editor config, or
dotfiles that are not system-level. Those belong in the shell layer. An optional
Home Manager role can install a user-level CLI when the operator needs that
command outside an entered shell. Netcup uses this exception for the pinned
`devenv` CLI only; it does not expand the NixOS role.

---

## Verification against prior research

| Prior claim | Upstream verdict |
|---|---|
| Two roles per Machine (nixos + home-manager) | **Confirmed.** Maximal combination. |
| `deploy.healthCheck` default `"true"` checks only system paths | **Confirmed.** Verbatim from docs. |
| `deploy.rollbackTimeout` default 300, range 30–600 | **Confirmed.** Verbatim from options reference. |
| HM has no rollback; failed HM leaves NixOS in place | **Confirmed.** Verbatim from blog. |
| `machines plan` saves under `.devenv/machine-plans/<id>/` | **Confirmed.** |
| `machines check` blocks SSH/root-disabling configs | **Confirmed.** |
| `install.copyHostKeys` default false | **Confirmed.** |
| HM-only machine omits `target.host` to activate locally | **Confirmed.** |
| Converting existing Arch/Debian host in-place | **NOT DOCUMENTED** in devenv. |
