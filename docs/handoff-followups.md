# Handoff — netcup follow-ups

Written 2026-09-27 at the end of the session that installed the host, and
**updated later the same day** when `add-netcup-tailnet` landed. For the next
session, which should decide the follow-ups **before** writing code.

This document deliberately does not restate what the specs and the archived
change already say. It carries: the live state, the decisions that are open,
the mechanics that will otherwise be rediscovered, and the evidence index.

> **Update — 2026-09-27, `add-netcup-tailnet`.** Follow-up 2's *tailnet half* is
> settled: the host is enrolled as `nc.worm-hue.ts.net` (`100.95.168.15`, tag
> `tag:server`), reaches the tailnet unattended, and survives a reboot without
> the auth key. The procedure of record, the new traps, and what remains
> unverified are in **`docs/tailnet-netcup.md`** — read that, not this section.
> What is *not* settled is the tailnet half of **follow-up 1**: making the
> overlay the only access path, which is what §3's menu item (a) now depends on.
> §4's numbered list is therefore answered-and-retired except for its item 2;
> §8's questions 2 and 3 are updated below.

---

## 1. Where things stand

`~/nix` is the live repository and the netcup host now runs the NixOS it
declares. The change `2026-09-27-add-netcup-bare-install` is **archived**; its
requirements are promoted into `openspec/specs/`.

| | |
|---|---|
| Host | netcup VPS, `152.53.92.126`, 12 vCPU / 32 GiB, single `/dev/vda` |
| Running | `26.11pre-git (Zokor)`, installed 2026-09-27 in **347 s** by one `./bin/devenv machines install netcup` |
| Layout | GPT, 1 GiB ESP at `/boot`, btrfs root `subvol=/@`, `@home`, `@nix`, `@var`, `compress=zstd:3,noatime`, no swap, no LUKS |
| Access | key-only SSH, port 22, from the **public** address — *and, since this change, over the tailnet*; one key for `root` and one for `hbohlen` |
| Tailnet | `nc.worm-hue.ts.net` / `100.95.168.15`, tag `tag:server`, enrolled 2026-09-27 — procedure in `docs/tailnet-netcup.md` |
| Secrets | `secretspec.toml` now exists (1Password `dev`, `TS_AUTH_KEY` only). This drags the vault onto **every** `devenv machines` invocation, read-only `info` included — measured, and accepted on purpose |
| Verified | `scripts/postinstall-verify.sh` (all green) + a deliberate reboot returning in 23 s; and, since this change, `scripts/tailnet-verify.sh` + `scripts/tailnet-reboot-check.sh` |
| Deploy state | **`deploy` has now run** (2026-09-27, twice) — `machines status netcup` reports `outcome: "succeeded"`, no longer `phase: "uninitialized"`. It must still be root (§3) |

Specs: `openspec/specs/{netcup-machine,netcup-disk-layout,netcup-install,netcup-tailnet,netcup-operations}/spec.md`
Evidence and reasoning: `openspec/changes/archive/2026-09-27-add-netcup-bare-install/`
Tailnet evidence and reasoning: `openspec/changes/archive/2026-09-27-add-netcup-tailnet/`
Procedure and pitfalls: `docs/install-netcup.md`
Tailnet (node, enrollment, traps, what is unverified): `docs/tailnet-netcup.md`

## 2. What was deliberately left out, and why

Three things are absent on purpose. Each is one follow-up change, and each adds
exactly one moving part:

1. **Hardening — closing root login.** The deployed host accepts root key login.
   That is the price of `devenv machines` requiring root SSH (§3).
2. **Tailnet access.** ~~The host has no tailscale. The old tailnet node `nc`
   (`100.95.92.47`) is still registered but **offline — last seen
   2026-09-27T13:10Z**, i.e. it is the wiped Debian install. Re-enrolling the
   host will collide with that stale registration (`tailscale` keeps the name).~~
   **SETTLED 2026-09-27 by `add-netcup-tailnet`.** The stale node was deleted, the
   host enrolled as `nc` (unsuffixed, as intended) and carries `tag:server`, and
   the overlay comes up unattended across a reboot without re-reading the auth
   key. `docs/tailnet-netcup.md` is the procedure of record. What remains open is
   *follow-up 1's* half — making the overlay the only access path.
3. **Everything else**: host-side secrets, snapshots, zram/swap, operator
   tooling on the host, a second host (`oci`). Not discussed, not designed.

## 3. Follow-up 1 — closing root login, and the deploy path it closes

**The tangle, in one line:** `devenv machines` install *and* deploy need root
SSH, so any hardening that closes root login also removes routine deploys.

> **Update 2026-09-28, after `add-netcup-self-deploy` archived.** The routine
> deploy now happens ON the host, over `root@localhost`, under the loopback
> identity `hosts/netcup/default.nix` declares for root (`docs/self-deploy-netcup.md`,
> design D4). So this follow-up's trade is narrower than it was: a
> `Match Address` restriction has to keep `127.0.0.1` reachable or it breaks the
> host's own loop — recorded as risk R7 — while the WORKSTATION's root path is
> what closing root login would actually end. Carry the loop's constraint into
> the design of this follow-up rather than discovering it there.

What is already measured (do not re-derive):

- Current posture on the live host: `/etc/ssh/authorized_keys.d/root` holds
  exactly one key, shared with `hbohlen`; password auth is refused.
- In the pre-install experiment, a config with `PermitRootLogin = "no"` and no
  root key produced `installCheck.hasRootAuth = false` and
  `ssh.rootLogin = "no"` — a configuration Machines cannot install or deploy.
- The deployed config sidesteps this with `PermitRootLogin = "prohibit-password"`
  plus a root authorized key.

**Measured later the same day (2026-09-27) — non-root deploy does NOT work. This
is settled by measurement, not by the docs.** Run with the target overridden at
the CLI (`-O machines.netcup.target.host:string hbohlen@152.53.92.126`, so no
file was edited), with the sudo theory's precondition actually in place:
`hbohlen@` has passwordless sudo on the target (`sudo -n id -u` → `0`; wheel plus
`wheelNeedsPassword = false`). Both paths still refused:

- `machines status netcup` exits 1 on a literal remote guard and never attempts
  sudo: `test "$(id -u)" = 0 || { echo 'Deployment status requires root SSH'
  >&2; exit 1; }`.
- `machines deploy netcup --yes` builds, evaluates and prints the plan, then dies
  at the first write: `nix copy --to ssh://hbohlen@152.53.92.126 …` →
  `cannot add path … because it lacks a signature by a trusted key` — a non-root
  user on the target is not a trusted user. Activation is never reached.
- Deeper, from the built executor
  (`devenv.config.machines.netcup.build.deployer`): its docstring is "Root-only
  NixOS deployment executor, invoked over SSH"; `main()` ends in
  `if os.geteuid() != 0: parser.error("the machine executor requires root")`;
  activation is `<system>/bin/switch-to-configuration switch` plus `systemctl`.
  The **only** sudo branch in devenv's machine scripts is in the *nix-darwin*
  activate script (`… else sudo -H -- … HOME=/var/root …`) — exactly what the
  docs say (NixOS needs root SSH; nix-darwin may use an admin with passwordless
  sudo). `MachineTarget` has two fields (`host`, `sshOpts`): there is no knob.

**`install` is root by nature for the same reason, so this does not end at
deploy.** Its preflight runs `echo "user=$(id -u)"` on the target and refuses
with "install requires root SSH access, but the current user on the target has
uid N. Either SSH in as root or configure root login on the target."; the kexec
phase pipes a tarball into `/root` (`curl … | tar xzf - -C /root &&
/root/kexec/run`); and install refuses a config declaring no root auth, because
`nixos-install` runs with `--no-root-password`.

The menu, corrected:

- **(a)** Keep root key-only, confined with a `Match Address` block to the
  tailnet once follow-up 2 lands.
- **(b)** ~~A dedicated deploy account the installer/activator accepts~~ —
  **dead as written.** The NixOS activator accepts root only, and an account the
  *installer* would accept cannot exist at all. Only nix-darwin has a sudo path.
- **(c)** Keep root-key SSH permanently and stop treating it as debt.
- **(d)** Whatever replaces deploys entirely — e.g. `devenv machines install`
  only, on re-image. The limit this now carries: **install always needs root
  once**, so a re-image needs the provider console or a temporary root key even
  if root login is otherwise closed.

Side observation from the refused run (useful before touching the host): its plan
compared `Running` / `Profile` / `Requested` as one identical store path with
`Closure: +0 / -0 store paths` — the live host currently matches exactly what
this repo declares.

**Spec note:** `netcup-machine`'s SSH requirement *currently requires* root key
SSH, so this follow-up is a **MODIFIED** requirement, not an addition. Read the
existing text before writing a delta.

## 4. Follow-up 2 — tailnet access

**Status: items 1, 3 and 4 are SETTLED (2026-09-27, `add-netcup-tailnet`); item 2
is the live remainder, and it is what follow-up 1 waits on.** Read
`docs/tailnet-netcup.md` for what was built; the summaries below record only
which decision was taken and why it is closed.

1. **Enrollment mechanics.** ~~`install.secrets` can deliver a tailscale auth key
   during install (that was the headline reason to like Machines), or `tailscale
   up` can stay a manual post-boot step.~~ **Decided: `install.secrets`.** The key
   is declared once and delivered to `/var/lib/tailscale/authkey`, which the
   generated `tailscaled-autoconnect.service` reads. Consequence accepted
   explicitly: once `secretspec.toml` exists, **every** `devenv machines`
   invocation resolves the whole profile, so the 1Password vault is now on the
   `machines` path. The live host was brought to the same state by
   `scripts/tailnet-enroll.sh` instead, because `deploy` does not refresh
   bootstrap files. **The install-time delivery itself is still unverified — it
   needs a re-image.**
2. **Does the tailnet become the ONLY access path?** If yes, the public sshd
   exposure goes away and root-key login can be confined to `tailscale0`. This
   is where follow-ups 1 and 2 fuse into one design.
3. **Secrets plumbing.** ~~The tailscale auth key currently exists only as
   `TS_AUTH_KEY` in the *old* repo's Proton Pass manifest
   (`~/projects/nixos/secretspec.toml`). This repo has no manifest and uses
   1Password.~~ **Settled: 1Password `dev` is this repo's secretspec provider**
   (`secretspec.toml`, `TS_AUTH_KEY` → `onepassword://dev`). Both consequences
   named here held and are now measured fact: 1Password was already a Hermes
   secret source, and the profile-resolution trap is real — the vault is on
   every `machines` path. The item's field is `credential`, not `password`.
4. **Naming and ACLs.** ~~The stale `nc` node must be resolved; decide the
   intended MagicDNS name …~~ **Settled:** the stale node was deleted, and the
   name is pinned with `extraUpFlags = [ "--hostname=nc" ]` — deliberately not
   by renaming the host, so `networking.hostName` stays `netcup`. Tags come from
   the key (`tag:server`); no other ACL change was made by this change.
5. **Host-side secret management, if any.** secretspec is a bootstrap path, not
   a runtime one — sops-nix or agenix is the long-term shape if the host ever
   holds secrets at rest.

## 5. Cross-cutting decisions

- **1Password as this repo's secretspec provider.** Vault `dev` holds
  `NETCUP_CONSOLE` and `SSH Key`, and nothing else that is a static secret.
  Which secrets does this build actually need? A short list beats a manifest
  invented up front.
- **What goes in the operator half of `devenv.nix`?** It is empty by design
  (one file, two consumers: `devenv shell` and `devenv machines`). Tooling
  graduates in only when it proves durable.
- **ADRs?** This repo has none. `~/projects/nixos` has five, all written against
  a different host and direction — reference, not truth. If a decision here is
  expensive to reverse (the tailnet-only access choice is), it may deserve one.
- **Settled, do not reopen:** the nixos-facter report is gitignored while
  `hardware.facter = null`. Reasoning is in the archived design's open
  questions.

## 6. Mechanics a fresh session needs (and will otherwise rediscover)

- **Use `./bin/devenv`, not `devenv`.** Bare `devenv` on this workstation is
  2.2.2 and has no `machines` subcommand; the repo pins 2.4.0 and gcroots it.
- **Test an access hypothesis without editing `devenv.nix`:** override the target
  on the command line, e.g. `./bin/devenv machines status netcup -O
  machines.netcup.target.host:string hbohlen@152.53.92.126`. `status` and
  `check` are read-only; only `deploy` builds and activates.
- **Never run bare `devenv update`.** It moves `devenv.lock`'s `devenv` input to
  the default branch (measured: main's `bd08a52`), which the pinned binary was
  never built against. It is pinned to `v2.4.0` in `devenv.yaml`; update inputs
  by name.
- **Host identity** is the 1Password `dev` item `SSH Key`,
  `SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ` — **not** the
  workstation's own `~/.ssh/id_ed25519`. Materialize it with `op inject` into a
  `0600` file, and **append a trailing newline** (the injected value lacks one
  and `ssh-keygen` calls it `invalid format`). It is currently at
  `~/.ssh/id_ed25519-op-dev`; `devenv.nix` carries it in `target.sshOpts`.
- **1Password access from the agent** works: the service-account token is in
  `~/.hermes/.env` as `OP_SERVICE_ACCOUNT_TOKEN` (a copy also sits at
  `~/.config/op-sa-token`, mode 0600). `op vault list` → `dev`. Never
  `op item get --format json` an item: it does **not** redact.
- **`~/.ssh/config`** had the old repo's fragment included; it aborts *every*
  ssh call in a non-interactive environment because of a `${XDG_RUNTIME_DIR}`
  `IdentityAgent` line. The Include is now disabled (backup
  `~/.ssh/config.bak-20260927`). If ssh misbehaves, this is the first suspect.
- **Checking the host:** `scripts/preflight.sh` (gates),
  `scripts/postinstall-verify.sh` (evidence), `scripts/reboot-check.sh`
  (unattended boot). Their headers record the NixOS quirks that make a naive
  check report false failures — authorized keys live in
  `/etc/ssh/authorized_keys.d/`, `findmnt` takes one target per invocation,
  `lsblk` collapses btrfs subvolume mounts.
- **Boot detail:** the host boots from the UEFI fallback binary
  `/boot/EFI/BOOT/BOOTX64.EFI` (no NVRAM entry, `canTouchEfiVariables =
  false`). It is load-bearing — do not "clean up" `/boot`.
- **`~/projects/nixos` is reference material.** Nothing may be inherited by
  copying; if a decision is reused, say why it still holds.

## 7. Suggested skills for the next session

- `software-development/openspec-change-authoring` — specs before code, which is
  this repo's convention (`openspec/config.yaml` carries the constraints).
- `devops/nixos-host-config` — module and eval hygiene.
- `devops/nixos-remote-deploy` — the deploy path this repo deliberately differs
  from, useful as contrast.
- `devops/onepassword-cli-secrets` — vault access without leaking material.
- `bb-cli` + `devops/herdr-pane-control` — if a long or risky step should run in
  a visible pane rather than an invisible tool call.

## 8. Questions to answer in the next session

1. ~~Does `devenv machines deploy` work non-root?~~ **Answered 2026-09-27: no.**
   Deploy, status and install are all root-only by construction; see §3. §3's
   menu is therefore already narrowed to (a) / (c) / (d).
2. After the tailnet lands, is public SSH closed entirely? **(Still open — this
   is now THE question, and it is follow-up 1's, not follow-up 2's.)** The tailnet
   has landed and the public path is untouched: closing it is a deliberate
   later change, and it is what lets §3's menu item (a) exist at all. One
   exception is already fixed and cannot be designed away: `devenv machines
   install` needs root once, so a re-image needs the console or a temporary root
   key — §3.
3. ~~Does the auth key get delivered at install time (`install.secrets`) or
   manually after boot?~~ **Answered 2026-09-27: at install time** — declared in
   `secretspec.toml` + `devenv.nix`, read from `/var/lib/tailscale/authkey` by
   the generated unit. The live host was enrolled by script instead (a deploy
   cannot write bootstrap files); the install-time delivery is the part that
   still needs a re-image to prove.
4. Which secrets does this build actually need, and do they go in 1Password?
5. Is a second host (`oci`) in scope this year, or does the module shape stay
   single-host until it is?
