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
| Live host vs. the checked-out tree | `Closure: +0 / -0` — the host already matches its declaration | the deploy plan printed by `bin/devenv machines deploy netcup` before the refused non-root run (`docs/handoff-followups.md` §3) |

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
| D3 | Vault position | keep `secretspec.enable: true` and make the profile resolvable **on the host** | `enable: false`, which trades away install-time enrollment; `SECRETSPEC_PROVIDER` wholesale override — **measured in task 2.1** to displace the per-secret provider and to need the value in the host's environment on every invocation, so it saves nothing and costs install-time delivery |
| D4 | Loopback deploy identity | a **loopback-only** keypair whose private half lives at the one declared `sshOpts` path, public half declared in the module that authorizes root | materializing the vault's `SSH Key` on the host; overriding `sshOpts` per invocation (no supported `-O` type) |
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

**Rejected, measured rather than assumed (task 2.1).** The wholesale
`SECRETSPEC_PROVIDER` override was the route to prefer *if* it could be shown to
introduce no credential at all, so it was measured in a scratch copy under
`/tmp` — never the repository — with `OP_SERVICE_ACCOUNT_TOKEN` unset, against
`secretspec` 0.21.0 as bundled by the pinned toolchain:

- No override (control), token unset: exit 1,
  `Provider operation failed: Provider operation failed: No accounts configured for use with 1Password CLI`.
- `SECRETSPEC_PROVIDER=env` with `TS_AUTH_KEY` present in the environment: exit 1,
  verbatim:

  ```
  × Provider operation failed: the env provider does not support the `field` coordinate. Drop `field` from the ref for `TS_AUTH_KEY`, or give this provider its own address with `refs.<alias>` or an alias `ref` template (0.19+): https://secretspec.dev/concepts/references/#different-coordinates-per-provider-019
  ```

  `dotenv` fails identically.
- The same scratch manifest with `field` dropped from `TS_AUTH_KEY`'s `ref`:
  exit 0, and `install.secrets`' `TS_AUTH_KEY` resolves from the override rather
  than from `dev`.

The first error is decisive on exactly the point OQ2 asked about. The `env`
provider was consulted for a secret the manifest declares `providers = ["dev"]`,
so **the override does displace the per-secret provider** — it fails outright
against the manifest as it stands, and substitutes silently once the manifest is
edited to suit it. Both repairs are manifest edits (`refs.<alias>`, or dropping
`field`), and either one changes the coordinate through which `dev` and
`install.secrets` are resolved.

It also does not deliver the property it was preferred for. Making the override
resolve requires the value to be present in the host's environment on every
invocation; measured with the variable absent, exit 1 with
`Missing required secrets: TS_AUTH_KEY`. A value that must be exported for every
`machines` call on a public VPS is a credential at rest by another name — in a
plaintext environment file rather than a root-only `0600` one — so the route buys
no reduction in exposure and pays with install-time delivery.

The chosen route therefore stands, on evidence: `enable: true`, and a read-only
service-account credential on the host, root-only `0600` (R4) — plus, measured
since and recorded as R10, the `pkgs._1password-cli` binary that provider wraps,
without which the credential resolves nothing.

### D4 — A loopback-only key at the one declared identity path

Measured: `/root/.ssh/` is empty, so the loopback target has no client identity
and cannot work today. Two facts fix where that identity must live:

- The repository's single `target.sshOpts` declaration (`devenv.nix`) names
  `-i /home/hbohlen/.ssh/id_ed25519-op-dev -o IdentitiesOnly=yes`, and
  `IdentitiesOnly=yes` disables ssh's default key lookup — a key at any other
  path is invisible to that declaration.
- The per-invocation escape hatch is closed: `bin/devenv machines deploy --help`
  reports `-O, --option <OPTION:TYPE> <VALUE>` with supported types `string,
  int, float, bool, path, pkg, pkgs` — no type replaces a string list, so
  `sshOpts` cannot be overridden per invocation and must be right as declared.

Three candidates:

- **Chosen:** a dedicated loopback keypair whose *private* half is installed on
  the host at the declared path — that path is the vault key on a workstation
  and the loopback key on the host, so the one declaration means the same thing
  on both machines. The pair is generated in a scratch directory outside the
  repository (task 1.2), its public half is declared where root's authorized
  keys are declared, and the private half is installed root-owned `0600` at the
  path (task 3.3) with the scratch copy deleted. After that the loopback path
  depends on nothing outside the host, and no vault-derived key is at rest on a
  public VPS.
- **Rejected:** materializing the 1Password `SSH Key` on the host. `devenv.nix`
  already pins that key's path for the workstation, so a second copy on the host
  would collide with the very path this design needs — and it would put the
  vault's identity at rest for a loop that only ever crosses the loopback.
- **Rejected:** overriding `sshOpts` per invocation — the earlier draft's route,
  dead as written. The measured `-O` types cannot express a string list; the
  host-side invocation would inherit the workstation's `-i` path and
  `IdentitiesOnly=yes` would then exclude every other key. That is why the
  chosen route fixes the path rather than the invocation.

Measured once the route was applied (tasks 4.2–4.4, 2026-09-27), and it is the
one place the single-path rule does not reach: **the path fixes `ssh` as `devenv`
invokes it, not every consumer of the loopback address.** `ssh -i
/home/hbohlen/.ssh/id_ed25519-op-dev root@localhost id -u` returns `0` (task
4.2), but nix's own ssh store transport builds its own `ssh` command and never
reads `target.sshOpts`, so it finds no identity and fails:

- `nix store info --store ssh://root@localhost` → exit 1,
  `root@localhost: Permission denied (publickey)`,
  `error: failed to start SSH connection to 'localhost'`
- `nix copy --to ssh://root@localhost <path>` → the same

Naming the identity in `NIX_SSHOPTS` fixes both, and the copy then transfers 0
paths — which is R1 settled. The host-side deploy therefore carries `NIX_SSHOPTS`
naming the declared path, set by the declared wrapper rather than remembered by
the operator; R9 records the limit. The key still lives at exactly one path, and
that path is still the whole mechanism for `devenv`'s own connection.

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

- **[R1] The transfer step is unverified.** — **SETTLED 2026-09-27 by task 4.4:
  a copy to the same store IS a no-op.** `deploy` unconditionally runs
  `nix copy --to ssh://<target>`, and when source and destination are the same
  store — exactly what a loopback target means — the behaviour is documented
  nowhere. Measured on the live host:
  `nix copy --to ssh://root@localhost /nix/store/xsw8a0ck03cf1kgr5f83wqcmggmdbhqv-nixos-system-netcup-26.11pre-git`
  printed `copying 0 paths...` and exited 0, and a second copy of an unrelated
  store path did the same. The one step that could have invalidated D1 does not,
  so D1's rejected fallback — losing the plan, the watchdog and `status` — is not
  needed. The measurement also produced a precondition that is now part of the
  design: the copy only works when the loopback identity is named in
  `NIX_SSHOPTS`, because nix's ssh store transport never reads `target.sshOpts`
  (see D4 and R9).
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
  already accepts for the tailnet auth key. The alternative that promised to add
  no credential (D3's provider override) was measured in task 2.1 and rejected:
  it displaces the per-secret provider `install.secrets` depends on, and it needs
  a value in the host's environment on every invocation. **Accepted knowingly,
  not pending** — the residual exposure is one read-only vault credential, and no
  measured alternative has a smaller one.
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
- **[R9] `target.sshOpts` does not reach every consumer of the loopback
  address.** Measured 2026-09-27 (tasks 4.3/4.4): with the declared key correctly
  installed, `nix store info --store ssh://root@localhost` and
  `nix copy --to ssh://root@localhost <path>` both failed with
  `root@localhost: Permission denied (publickey)` →
  `error: failed to start SSH connection to 'localhost'`, because nix's ssh store
  transport builds its own `ssh` invocation and never reads `target.sshOpts`.
  → The host-side deploy runs with `NIX_SSHOPTS` naming the declared path, set by
  the declared wrapper rather than remembered by the operator — the same shape as
  the `OP_SERVICE_ACCOUNT_TOKEN` and `SECRETSPEC_REASON` exports
  `scripts/bb-pane-run.sh` already performs. Any later procedure that calls nix
  against `ssh://root@localhost` directly must do the same. This is a limit of the
  single-path rule, not a reason to abandon it: `sshOpts` describes devenv's own
  connection, and nothing else.
- **[R10] The host needs the 1Password CLI, not only the credential.**
  SecretSpec's 1Password provider is a WRAPPER AROUND THE `op` BINARY rather than
  an API client, so D3's credential at rest is necessary but not sufficient.
  Measured 2026-09-27 on the workstation by putting a sentinel `op` first on
  `PATH`: `machines info` invoked it as `vault list --format json` and failed
  with the sentinel's own message; the pinned secretspec 0.21.0 also carries the
  literal string `OnePassword CLI (op) is not installed.` Two measured details
  came out of fixing it: (a) `pkgs.onepassword` — the name secretspec's own
  install hint prints (`nix-env -iA nixpkgs.onepassword`) — does not exist in the
  pinned nixpkgs, and `pkgs._1password` is now a `throw`; the real attribute is
  `pkgs._1password-cli` (2.39.0, `mainProgram = op`, the same version the
  workstation runs); (b) it is unfree, and a Machine may not set `nixpkgs.config`,
  so `allow_unfree: true` is declared in `devenv.yaml`. →
  `pkgs._1password-cli` is declared in the host's self-deploy module. Consequence
  for the runbook: G1's deploy must carry the CLI, so a host that was bootstrapped
  before this finding needs one more deploy before any of group 6 can pass.

## Migration Plan

Every step below is a `deploy`; none is an `install`, and the disk layout is not
touched, so the host never needs re-imaging for this change. Ordering is
cheapest-first, and each gate has a command whose output settles it.

| Gate | Step | Settled by |
|---|---|---|
| G0 | Eval only, from the workstation | `bin/devenv machines info`, `machines check netcup`, `eval machines.netcup.build.nixos` — no host contact |
| G1 | Bootstrap: deploy this change **from the workstation** (D7), landing the declared nix settings, `pkgs.git`, `pkgs._1password-cli` (R10, added after the first bootstrap), and the loopback authorization; then install the loopback private half at the declared identity path | `machines deploy netcup --yes`, then `machines status netcup`; the key file's mode and owner read back |
| G2 | Isolated host probes, no devenv: nix features, a trusted/root identity, `ssh root@localhost`, and **R1's copy-to-self** | `nix store info --store ssh://root@localhost`; `nix copy --to ssh://root@localhost <present path>` — **both with `NIX_SSHOPTS` naming the declared loopback identity, or nix never finds it (R9)** |
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

1. **RESOLVED 2026-09-27 by the operator: a new PUBLIC GitHub repository
   `hbohlen/nix`, with `main` as the branch name.** The repository was
   jj-colocated in detached HEAD with no bookmarks, so `main` is created as a jj
   bookmark at the working-copy revision and pushed with `jj git push`. PUBLIC,
   at least initially, because the task 5.2 clone then needs NO credential on the
   host: a private repository would require a deploy key or a token at rest on
   the public VPS, a worse trade than world-readable configuration. The cost is
   accepted explicitly rather than discovered later — the published content
   includes the host's public IPv4, its tailnet address and node key, the
   operator's SSH **public** key, and the names of the 1Password vault and its
   items (never a value). Audited before the first push: no private key, no
   token, and no secret value appears in the working tree or in any of the 37
   commits. Going private later means making the clone credential-bearing, which
   is its own change. The same audit found one file tracked AGAINST
   `.gitignore:15`: `.machines/netcup/facter.json`, the 88 KB hardware report
   `devenv machines install` writes, which the rule excludes because "tracking it
   would make a later switch to the default facter path silently import a stale
   report". It carries no credential, but it is a build byproduct this tree says
   not to track, so it is untracked at the tip; it remains in the ancestry at
   868f8c9, and purging it would need a rewrite of that commit.
2. **RESOLVED 2026-09-27 by task 2.1 — the credential at rest (D3's chosen route);
   the wholesale provider override is rejected.** Measured in a `/tmp` scratch
   copy; the override fails exactly where this question predicted, consulting the
   `env`/`dotenv` provider for a secret the manifest declares
   `providers = ["dev"]` and rejecting the `field` coordinate, and making it
   resolve costs both a manifest edit and a value in the host's environment on
   every invocation. D3 carries the verbatim error and all three probes; R4
   records the residual exposure as accepted rather than pending. Nothing in this
   change still treats the mechanism as undecided.
3. **RESOLVED 2026-09-27 by task 4.4 — yes, `nix copy` to the same store is a
   no-op.** Against the host's own running system it printed `copying 0 paths...`
   and exited 0, so R1 does not invalidate D1. Settling it also exposed R9: the
   copy works only when `NIX_SSHOPTS` names the declared loopback identity,
   because nix's ssh store transport does not read `target.sshOpts`.
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
