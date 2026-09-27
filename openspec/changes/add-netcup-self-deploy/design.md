## Context

`devenv machines deploy` builds where it runs and then copies the result to
`target.host` over SSH. Every deploy of netcup today therefore runs on the
operator workstation, and the host cannot rebuild itself. That is not a
convenience problem: the host is the only machine in this system that must be
able to reconstitute itself, and the workstation is a second machine that must be
present, booted and holding the vault for the host to change at all.

Two documented facts fix the shape of the alternative:

- "By default, devenv builds on the machine running the command." A deploy run on
  the host builds on the host, natively, with no remote builder. The
  `--use-machines-as-builders` path is for cross-platform fleets and needs the
  C-Nix backend; it is not required here and is not used.
- "NixOS deployment and installation require root SSH… Setting it to `localhost`
  still uses SSH." There is no local-activation mode for a NixOS role. The
  `deploy me` form in the docs activates locally only for a machine with **no**
  `target.host`, which is available to home-manager-only machines. This host is a
  `nixos` role, so "local" means `root@localhost` over the loopback.

State of the live host and the repository, measured 2026-09-27 during this
change's research (read-only probes over the existing vault identity):

| Fact | Value | Command |
|---|---|---|
| Host NixOS / nix | `26.11pre-git`, nix 2.34.8 | `nixos-version`, `nix --version` |
| `experimental-features` | **empty** | `grep -E 'experimental-features' /etc/nix/nix.conf` |
| `trusted-users` | `root` | `grep trusted-users /etc/nix/nix.conf` |
| substituters | `cache.nixos.org` only | same file |
| `/root/.ssh/` | **empty** | `ls -la /root/.ssh/` |
| `ssh root@localhost` | `Permission denied (publickey)` | `ssh -o BatchMode=yes root@localhost id -u` |
| `nix store info --store ssh://root@localhost` | fails to start the SSH connection | as written |
| `git`, `op`, `devenv`, `jq` | absent | `command -v` |
| Capacity | 12 vCPU, 31 GiB, 1021 G free | `nproc`, `free -g`, `df -h` |
| Pinned toolchain in `devenv.cachix.org` | **present** (`axhrys71…-devenv-wrapped-2.4.0`) | `nix path-info --store https://devenv.cachix.org` |
| Same toolchain in `cache.nixos.org` | 404 | as written |
| `git remote -v`, `git branch --show-current`, `jj bookmark list` | all empty; jj-colocated, detached HEAD | as written |
| Live host vs. the checked-out tree | `Closure: +0 / -0` — the host already matches its declaration | handoff record |

The vault's position on the `machines` path was measured directly, because it
decides the whole design. With no `OP_SERVICE_ACCOUNT_TOKEN` in the environment,
`bin/devenv machines info` exits 1 with `Provider operation failed: No accounts
configured for use with 1Password CLI`. Three attempts to remove that
requirement, each run from the repository root:

| Attempt | Result |
|---|---|
| `-O secretspec.enable:bool false` | still resolves, exit 1 |
| `--secretspec-profile <a profile with no secrets>` | still resolves, exit 1 |
| `secretspec: enable: false` in `devenv.yaml` | exit 0, no vault needed |
| `secretspec.toml` deleted from the tree | exit 0, no vault needed |

So the vault is not structurally required — it is required by the `enable: true`
value in `devenv.yaml`, and no command-line override displaces it.

## Goals / Non-Goals

**Goals:**

- netcup holds its own checkout of this repository and rebuilds its own system
  from it, with no second machine in the loop.
- One Machine declaration for the host; the loopback destination is chosen per
  invocation, so there is no local/remote drift.
- Every precondition the host-side loop needs (nix features, a trusted or root
  identity, a loopback deploy identity, the pinned toolchain, `git`, a resolvable
  SecretSpec profile) is **declared in this repository**, not applied by hand to
  the running system.
- Each claim has evidence that can be re-read after the session that produced it.
- The public access path and the firewall facts are untouched.

**Non-Goals:**

- Closing root login, changing `PermitRootLogin`, or confining sshd to the
  overlay. This change makes root SSH permanently load-bearing and thereby
  constrains that work; it does not perform it.
- Installing or re-imaging the host. An install kexecs an installer over root SSH
  from outside and cannot run on the machine whose disk it is about to partition,
  so a first install and every re-image still need an outside machine
  (the provider console, or the workstation). This change reduces that to
  installs only, and says so rather than pretending otherwise.
- Any change to the disk layout, `hosts/netcup/disko.nix`, `system.stateVersion`,
  or the bootloader.
- Moving the operator shell to netcup. The workstation keeps the planning root,
  the wiki and the vault. Only the deploy loop moves.
- A home-manager role for the operator on the host. The docs' local-activation
  form applies to a home-manager-only machine; combining roles carries a
  documented hazard (a home-manager failure leaves the NixOS deploy applied with
  no rollback) and is a separate change.

## Decisions

| # | Decision | Chosen | Rejected alternative |
|---|---|---|---|
| D1 | How the host rebuilds itself | `devenv machines deploy netcup` run **on** the host, with the documented `-O machines.netcup.target.host:string root@localhost` override | build-and-activate by hand, which loses the plan, the rollback and `status`; see below |
| D2 | How many declarations | one Machine, target overridden per invocation | a second `machines.netcup-local` declaration — two declarations of one host drift apart |
| D3 | Vault position | keep `secretspec.enable: true` and make the profile resolvable **on the host** | `enable: false`, which trades away install-time enrollment; `SECRETSPEC_PROVIDER` wholesale override, unproven and value-bearing |
| D4 | Loopback deploy identity | a **host-local** keypair, public half declared in the module that authorizes root | materializing the vault's `SSH Key` on the host |
| D5 | Which user runs the deploy | `root`, over loopback | adding the operator to `trusted-users`, a permanent wider grant |
| D6 | How nix features are enabled | declared `nix.settings`, not an ambient `NIX_CONFIG` | leaving it to the caller's environment |
| D7 | Ordering of the first application | the first deploy of this change comes **from the workstation** | attempting it from the host before the settings land |

### D1 — Deploy over loopback rather than activating a build by hand

`devenv build machines.netcup` on the host produces the system path with no SSH
involved at all, and `switch-to-configuration` could activate it directly. That
is rejected: it discards the reviewable plan, the confirmation, the health check,
the 300 s watchdog and the `status`/`rollback` pair — that is, everything that
made the machine declaration worth having. The fallback is kept in view because
D1 rests on an unverified transfer step (R1), and naming what is lost if we fall
back is what makes falling back a decision rather than a retreat.

A `nixos-rebuild` route is unavailable by construction: there is no flake
exporting `nixosConfigurations.netcup`, and `netcup-machine` forbids a competing
host-definition surface.

### D3 — The vault, argued in full because it is this change's one new trust decision

Every `devenv machines` invocation resolves the whole SecretSpec profile, so a
`deploy` run on the host — which uses **no secret value at all** — still requires
the profile to resolve. The measurements above leave exactly two viable routes,
and the difference between them is which existing property you are willing to
give up.

**Chosen: keep `enable: true`; make the profile resolve on the host.**
`install.secrets` is the only mechanism that makes tailnet enrollment a property
of the machine rather than of an operator's session, and `add-netcup-tailnet`
argued at length that enrollment must survive an unattended first boot because
the hardening change will close public SSH. Setting `enable: false` — measured to
work — would silently delete that property, and would additionally invert
`netcup-machine`'s two vault scenarios again, requiring a MODIFIED delta there.
Removing the manifest has the same effect. Neither is a trade this change is
entitled to make on the tailnet change's behalf.

What that costs is stated plainly: the host must be able to resolve the `dev`
vault's `default` profile without an operator at a prompt, which means a
credential on the host. The precedent is in the reference implementation, not
inherited by copying: ADR-0005 explicitly allowed *a vault client on the public
VPS* with named blast-radius rules, and that ADR's *premise* — netcup is the
operator workstation — is what ADR-0006 contradicted, not its posture. This
change re-earns a much narrower version of it: the credential is the read-only
service-account form already in `secretspec.toml` (`op item create` fails with
`(101) You do not have permission` for every category tried, while `op item get`
and `op item list` succeed), so its blast radius is *reading one vault*, not
writing one, and it is not the operator's own vault session.

The `SECRETSPEC_PROVIDER` alternative is recorded rather than dismissed: the
reference's `devenv.yaml` documents the wholesale provider override and its sharp
edge — it displaces per-secret providers, so it must be proven not to break
install-time delivery before adoption. It is the route to prefer *if* it can be
shown to introduce no credential at all, and it is a measurement, not an
assumption.

### D4 — A host-local key, not the vault's identity

Measured: `/root/.ssh/` is empty, so the loopback target has no client identity
and cannot work today. Two candidates:

- **Chosen:** generate a keypair on the host, declare its public half where root's
  authorized keys are declared, and point the host-side invocation's `sshOpts` at
  the private path. The loopback path then depends on nothing outside the host,
  and no vault-derived key is at rest on a public VPS.
- **Rejected:** materializing the 1Password `SSH Key` on the host. `devenv.nix`
  already pins that key's path for the workstation, so a second copy on the host
  would either collide with that path or need a second override — and it would
  put the vault's identity at rest for a loop that only ever crosses the
  loopback.

Consequence to accept knowingly: `root` acquires two authorized identities — the
operator's (public path) and the host's own (loopback). Both are key-only; this
adds no authentication *method*, only a second key.

### D5 / D6 — Running as root, and declaring the nix settings

`trusted-users = root` is measured, and a non-root copy to the host's store
already fails the trusted-signature check — the failure `docs/handoff-followups.md`
§3 records from the non-root deploy attempt. The executor also requires root by
construction (`if os.geteuid() != 0`). Running the host-side deploy as root is
therefore not a new privilege: it is the same privilege the executor takes, and
it avoids permanently trusting the operator's account on the host for the
narrower need.

`experimental-features` is empty on the host, so `devenv` cannot run there at all
today. A per-invocation `NIX_CONFIG="experimental-features = nix-command flakes"`
was sufficient for the probes and is the right tool for *testing before this
change lands*; it is not the right tool for the steady state, because a setting
that lives in the operator's environment is a setting that is missing whenever
someone else, or a script, runs the command.

## Risks / Trade-offs

- **[R1] The transfer step is unverified.** `deploy` unconditionally runs
  `nix copy --to ssh://<target>`. When source and destination are the same store
  — which is exactly what a loopback target means — the behaviour is documented
  nowhere. This is the one step that can invalidate D1. → Measure it in
  isolation, before any deploy: `nix copy --to ssh://root@localhost` against a
  path already present. If it refuses, fall back to D1's rejected alternative and
  record that the fallback costs the plan, the watchdog and `status`.
- **[R2] The control channel is circular.** The deploy's SSH control path is on
  the same host whose units activation restarts. If `switch-to-configuration`
  bounces sshd or dbus, the controller can lose the confirmation it is waiting
  for, and the watchdog can then roll back a system that was in fact fine. →
  The executor runs as a service on the target, which is what makes a severed
  session survivable at all; the first end-to-end test is a **no-op** deploy (the
  host already matches its declaration, `Closure: +0 / -0`), so nothing new is
  being started when this risk is first exercised; and the verdict is read from
  `machines status` afterwards rather than inferred from the transcript.
- **[R3] No independent channel.** Today a broken host can be repaired from the
  workstation. After this change the host is the primary path into itself, and a
  mistake on it can remove the operator's ability to fix it. → The tailnet is
  already live (`nc`, `tag:server`) and is the second channel; the provider
  console is the third. No single deploy may close both network routes, and the
  deliberate-failure test (gate G6) is run only with the tailnet reachable.
- **[R4] A credential at rest on a public VPS** (D3). → Read-only service-account
  scope, root-only `0600`, one item, and the same class of exposure the host
  already accepts for the tailnet auth key. The alternative that adds no
  credential (D3's provider override) is to be measured before this is treated as
  final.
- **[R5] Drift between the host's checkout and the pushed revision.** An edit made
  in place on the host and never pushed turns the host into a hand-maintained
  copy — the exact failure the single-declaration rule (D2) exists to prevent. →
  The revision comparison is a spec scenario, and the procedure makes pushing
  from the host part of the loop rather than an afterthought.
- **[R6] Bootstrap ordering.** The host cannot run `devenv` until D6's settings
  land, so the first application of this change must come from the workstation. →
  Stated as D7 and as the first gate; a host-side attempt before that fails with
  a confusing error that has nothing to do with the change.
- **[R7] Root SSH becomes permanent.** This change makes `PermitRootLogin =
  "prohibit-password"` load-bearing forever, so "close root login" is no longer
  available as written, and a `Match Address` scoped to the tailnet would not
  match `127.0.0.1`, silently breaking the loopback deploy. → Recorded as a
  constraint on the hardening follow-up and as a spec scenario
  (*Root over loopback is still permitted*), so the constraint is discovered in a
  proposal rather than during a deploy.
- **[R8] Unchanged and not this change's:** `devenv machines check netcup` still
  reports `access-analysis-incomplete` for the host's `dynamicKeys = true` facts.
  It will be reported after this change exactly as before it. The fix belongs to
  whoever owns the SSH posture, not here.

## Migration Plan

Every step below is a `deploy`; none is an `install`, and the disk layout is not
touched, so the host never needs re-imaging for this change. Ordering is
cheapest-first, and each gate has a command whose output settles it.

| Gate | Step | Settled by |
|---|---|---|
| G0 | Eval only, from the workstation | `bin/devenv machines info`, `machines check netcup`, `eval machines.netcup.build.nixos` — no host contact |
| G1 | Bootstrap: deploy this change **from the workstation** (D7), landing the declared nix settings, `pkgs.git`, and the loopback authorization | `machines deploy netcup --yes`, then `machines status netcup` |
| G2 | Isolated host probes, no devenv: nix features, a trusted/root identity, `ssh root@localhost`, and **R1's copy-to-self** | `nix store info --store ssh://root@localhost`; `nix copy --to ssh://root@localhost <present path>` |
| G3 | Get the checkout onto the host and build there: clone (or `scp` before the remote exists), the pinned toolchain from `devenv.cachix.org`, then build | `bin/devenv build machines.netcup` → the same `nixos-system-netcup-*` name the workstation produces |
| G4 | Vault resolution on the host, then the read-only machine operations over loopback | `machines info` exits 0 unattended; `machines check`/`status` against `root@localhost` |
| G5 | The no-op self-deploy — the real end-to-end test, and R2's first exercise | `machines deploy netcup -O machines.netcup.target.host:string root@localhost --yes`, then `machines status netcup` → succeeded, not rolled back |
| G6 | A real change, then a deliberate failure | add `pkgs.git`'s consumer or another trivial package and observe the change applied; then a configuration whose activation fails, and confirm the previous system is restored |
| G7 | Publish: the remote, the branch or bookmark, and a fresh clone on the host that evaluates the same Machine | `git remote -v`; `jj bookmark list`; `git rev-parse` on both sides |

Rollback: none of these steps removes a generation. `devenv machines rollback`
and the previous system generations remain available at every gate, and G6
exists precisely to prove that is true on a host-side deploy rather than assumed
from a workstation-side one.

## Open Questions

1. **Which remote, and which branch or bookmark name?** The repository has no
   remote, is jj-colocated in detached HEAD, and has no bookmarks — there is
   nothing to push yet. The remote's identity (new bare repository, existing
   hosting, the tailnet, or a local path) is an operator decision with no
   evidence in the tree to derive it from, so it is asked rather than guessed.
2. **Which mechanism makes the profile resolve on the host — a credential at rest
   (D3's chosen route), or a wholesale provider override that adds none?** The
   file-provider form must be measured, and specifically must be shown not to
   displace the per-secret provider that `install.secrets` depends on before it
   can be adopted.
3. **Does `nix copy` to the same store behave as a no-op?** (R1.) This is the
   single largest unknown in the design and it is cheap to settle.
4. **Does the deploy's control channel survive activation restarting sshd on the
   same host?** (R2.) The no-op deploy is the safe instrument; if it proves
   fragile, the answer may be a separate listener for the deploy path rather than
   the main sshd.
5. **Should the operator account also become trusted on the host**, or do deploys
   always run as root (D5)? Running as root is chosen; this records that the
   alternative exists if non-root invocation is ever wanted.
6. **Does the hardening follow-up keep root on loopback?** (R7.) This change
   assumes yes and writes that assumption into a spec scenario; if the answer is
   no, this capability does not survive the hardening change.
7. **Is a home-manager role for the operator on the host wanted later?** The
   docs' local-activation form would let that half deploy with no SSH and no
   root, while the system role still used loopback — with the documented hazard
   that a home-manager failure leaves the NixOS deploy applied with no rollback.
   Out of scope here; recorded so it is a decision and not a discovery.
