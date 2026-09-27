## Context

netcup boots the NixOS this repository declares and answers SSH on
`152.53.92.126` (`devenv machines info` → `netcup | x86_64-linux |
root@152.53.92.126 | nixos`). It has no overlay, and `devenv machines status
netcup` reports `{"phase": "uninitialized"}` — the deploy path this change will
be delivered by has never run against it.

The tailnet this host would join is `hbohlen.github` (MagicDNS suffix
`worm-hue.ts.net`), read from the operator workstation's own membership. The name
`nc` was held by the previous netcup host — ID `nwjHjrxuF521CNTRL`, `100.95.92.47`,
tags `["tag:server"]`, created `2026-09-27T04:31:08Z`, last seen
`2026-09-27T13:10:00Z`, offline, `KeyExpiry 2027-03-26T04:31:08Z` — and that node
has since been deleted. **Verified 2026-09-27:** `tailscale status` lists nine
peers and none is `nc`; `tailscale status --json` contains no peer whose
`HostName` is `nc` or whose `DNSName` begins `nc.`

Everything below was measured on 2026-09-27 against the pinned toolchain, not
recalled. Where a version matters, it is named.

### What the pinned modules actually do

Read from the machines this repository builds against:

- **The Machine's nixpkgs is not the flake pin.** `devenv.yaml` declares
  `inputs.nixpkgs = github:cachix/devenv-nixpkgs/rolling`, which resolves to
  `cachix/devenv-nixpkgs@c2f38fe7f9e04d9aadd354d380f2bd40531d9737` — a patch
  wrapper whose own `flake.lock` pins `NixOS/nixpkgs@c7def046b9a883d46974757852106483d741586f`.
  The wrapper's patches (`patches/*.patch`) touch poetry, lean4 and LLVM Darwin
  only, so the effective tailscale implementation is upstream's at that rev.
  Tailscale is version `1.102.4` there.
- **`services.tailscale.authKeyFile` is `types.path`, and a string satisfies
  it.** `authKeyFile = "/var/lib/tailscale/authkey"` is accepted (verified by
  evaluating `lib.types.path.check "/var/lib/tailscale/authkey"` against the
  pinned lib, which returned `true`, while a relative string returned `false`).
  A string is not a store path, so the value is not copied into
  `/nix/store` — this is the same string-not-path rule `devenv.yaml` already
  states for secret source paths.
- **The file drives a generated unit, not a `tailscaled` exec line.** Setting
  `authKeyFile` creates `systemd.services.tailscaled-autoconnect` (`after` and
  `wants` `tailscaled.service`, `wantedBy = [ "multi-user.target" ]`, `Type =
  notify`). Its script polls `tailscale status --json --peers=false |
  jq -r '.BackendState'` and calls `tailscale up --auth-key "$(cat
  <authKeyFile>)..."` only when the state is `NeedsLogin|NeedsMachineAuth|
  Stopped`; on `Running` it sends `systemd-notify --ready` and exits 0. The
  module also notes that `extraUpFlags` — which is where `--hostname=nc` goes —
  is applied only when `authKeyFile` is set.
- **There is no deploy-side secret path.** The Machine option tree has
  `install.{kexec,extraFiles,secretspec,secrets,encryptionKeys,copyHostKeys}`
  and `deploy.{facts,healthCheck,rollbackTimeout}`, and nothing else. The docs
  are explicit: "Bootstrap files are written only by `install`, not refreshed by
  `deploy`."
- **`install.secrets` writes byte-exact, atomically, after `mkdir -p`,** then
  `chmod`, `chown`, `sync -f` and `mv -T` over the destination; modes are
  validated to reject special and execute bits, group write, and every
  permission for other users. So `0600` is expressible and a missing parent
  directory is created.
- **Local SecretSpec execution is the default** (`execution = "local"`): devenv
  resolves on the workstation and streams the value over SSH. It requires
  SecretSpec to be enabled in `devenv.yaml`, whose `secretspec` block takes
  `enable`, `provider` and `profile` (`devenv.schema.json`, `$defs.SecretspecConfig`).
  Target execution instead requires the *installer* to reach the provider on its
  own — for a 1Password service account that means putting a service-account
  token on a temporary kexec environment, which is a strictly worse trade.
- **A local payload requires pinned SSH host keys.** "When an install sends
  local secrets, encryption keys, or extra files, devenv requires a known host
  key from its first connection and disables forwarding. Add the host keys for
  both the original host and the kexec installer if they differ."
- **Before the key exists, the counterexample is already observable.** Because
  the unit is `WantedBy=multi-user.target` and its loop only ends when
  `tailscale status` itself fails, a host with no file at `authKeyFile` starts
  the unit, loops on `cat: <path>: No such file or directory`, and is killed at
  systemd's default 90 s start timeout. That is what the state between the deploy
  and the enrollment looks like — a *failed* unit, not an idle one. The shipping
  consequence is in D8: the pre-enrollment check asserts the failure names the
  absent key path, so a failure for any other reason is not mistaken for it.
- **devenv's human output is ANSI-wrapped and `NO_COLOR` does not suppress it.**
  Measured 2026-09-27: `./bin/devenv machines info` emits `^[[0m` around every
  token of its table, with `NO_COLOR=1` no different. Anything parsing that
  output has to strip the escapes first; `devenv eval`'s JSON on stdout is clean.
- **`require_reason = true` costs every `devenv machines …` command an
  environment variable.** Measured 2026-09-27: devenv forwards NO reason flag —
  there is no `--reason` on the devenv CLI — so once a manifest is in the tree,
  `machines info`, `status`, `build`, `eval` and `deploy` all die with
  `Accessing secrets requires a reason` until `SECRETSPEC_REASON` is set. The
  scripts export it; a command typed by hand does not get it for free. This is the
  price of the audit reason, named rather than discovered.
- **devenv renders a progress TUI whenever stdout is a TTY.** Measured
  2026-09-27 in a bb pane: one build emitted **664,766 characters**, almost all
  spinner frames, burying every gate line above and below it. With `--no-tui` the
  same run came to **4,469 characters**. Under a non-TTY tool call devenv prints
  terse lines either way, so this is invisible until the command is run somewhere
  a human is watching — which is exactly what routing through a pane does.
- **A systemd unit's script body is not in the unit file.**
  `systemd.services.<name>.script` is built into its own store path and the unit
  carries only
  `ExecStart=…/unit-script-<name>-start/bin/<name>-start`. Measured 2026-09-27:
  the preflight's gate 7 failed on a CORRECT configuration because it grepped the
  unit for the key path. A grep that fails after an indirection you did not know
  about looks exactly like drift; follow `ExecStart` instead.
- **The ambient `secretspec` is not devenv's.** Measured 2026-09-27:
  `command -v secretspec` → `~/.cargo/bin/secretspec` **0.20.0**, while the
  pinned toolchain bundles **0.21.0** at
  `$(readlink -f .devenv-toolchain)/bin/secretspec`. A manifest verified with the
  ambient binary is verified against a resolver that will not be the one running
  `install.secrets`.

## Goals / Non-Goals

**Goals:**

- netcup is a tailnet member whose node name is `nc`, declared in this
  repository.
- The enrollment is a property of the machine, so the host can come back onto
  the overlay without an operator at a console — the precondition for ever
  closing public SSH.
- The auth key is a 1Password `dev` vault item read through SecretSpec, and no
  key material reaches the repository or the Nix store.

**Non-Goals:**

- Closing root login, changing `PermitRootLogin`, or disabling the operator's
  public SSH path. That is follow-up 1, and this change exists to make it
  possible rather than to do it.
- Confining sshd to `tailscale0`, or adopting Tailscale SSH. The tailnet is
  added as a second path here, not as the transport.
- MagicDNS as the host's resolver, exit nodes, subnet routers,
  `tailscale serve`/`funnel`, ACL edits, session recording.
- sops-nix or agenix. `install.secrets` bootstraps one file on first boot; it is
  not a runtime secret mechanism, and this change does not pretend otherwise.
- Any firewall change. `services.tailscale.openFirewall` defaults to `false`
  (verified in the pinned module), so no UDP port is opened and the
  `netcup-machine` scenario *Only the SSH port is exposed* stays true.

## Decisions

### D1 — Delivered by `deploy`, without re-imaging

The host is live and productive, and re-imaging it costs a provider-side OS
reinstall plus a full install. The change is therefore delivered by
`devenv machines deploy`, which needs only root SSH — which the host has. The
alternative, re-imaging so that `install.secrets` fires naturally, buys nothing
this change cannot get otherwise and destroys a working host to get it.

### D2 — Enrollment is declared through `authKeyFile` + `install.secrets`, and the live host is brought to the same state by hand, once

The two candidate mechanisms:

| | Enrollment at install time | Manual `tailscale up` after deploy |
|---|---|---|
| Mechanism | `install.secrets` → `services.tailscale.authKeyFile` → generated `tailscaled-autoconnect.service` | operator runs `tailscale up --auth-key` over SSH |
| Key at rest on the host | yes, at the declared path | no |
| A re-image re-enrolls unattended | yes | no |
| Survives closing public SSH | yes | no |
| Operator steps per host | zero after the vault item exists | one, and it must follow every re-image |

**Chosen: enrollment at install time, plus a one-time manual population of the
same declared path on the live host.**

The deciding property is not convenience, it is the change this one unblocks. A
configuration that closes public SSH is only survivable if the overlay is up
before the host is otherwise unreachable; that makes unattended enrollment a
hard requirement of the follow-up, not an optimisation. The manual path cannot
satisfy it, because the session that would run `tailscale up` is the session
that has just been locked out.

The live host reaches the same end state without a re-image: the declared path is
populated once from the vault, and the already-deployed
`tailscaled-autoconnect.service` does the rest. From then on there is exactly one
mechanism, exercised two ways.

**Named costs, accepted deliberately:**

1. A `secretspec.toml` in the tree makes the vault a prerequisite for *every*
   `devenv machines` invocation, including read-only ones. This is measured
   behaviour, recorded twice: ADR-0006 F5 in `~/projects/nixos` (a read-only
   `devenv machines info` refusing to run until six secrets resolved) and the
   `devenv.yaml` header in this repository from the other direction.
2. An auth key sits at rest on the host at the declared path. It is `0600
   root:root`, and it is what makes a re-image self-enrolling — removing it
   would leave a host whose node key is ever invalidated unable to re-enroll
   without an install.
3. The `install.secrets` half of this mechanism cannot be exercised until the
   next re-image. It will be declared, checked at eval time, and *unverified in
   execution* — the change says so in its tasks rather than implying the path
   was tested.

### D3 — The node name is pinned with `--hostname`, not by renaming the host

`networking.hostName` stays `netcup`. Renaming it to `nc` would silently
re-scope the host's prompt, journal identity, DHCP identity and the
`nixos-system-netcup-*` derivation name, and the archived change already decided
that the hostname is the declaration's business — not the tailnet's. The tailnet
name is therefore a tailnet fact, declared where tailnet facts live.

Consequence to keep in view: `extraUpFlags` applies at the `tailscale up` call
only. Migrating an already-enrolled node to a different name later is a
`tailscale set`/admin-console operation, not a config change.

### D4 — Local SecretSpec execution

`execution` stays at its `local` default. Target execution would require the
kexec installer to authenticate to 1Password by itself, which means placing a
service-account token in a temporary environment; local execution keeps the
credential on the workstation and streams only the one value. The provider
selection lives in the manifest (`[providers.dev] uri =
"onepassword+token://dev"`) and `devenv.yaml`'s `secretspec.provider: dev`
selects it by alias — verified: `secretspec check -p dev` resolves an existing
vault item (`SSH Key`/`fingerprint`) and reports the not-yet-created
`TS_AUTH_KEY` as `missing_required`.

### D5 — The key path is persistent, not the module's example path

`authKeyFile`'s own example is `/run/secrets/tailscale_key`. That is wrong here
and measurably so: `install.secrets` writes "after `nixos-install` and before
reboot" into the *installed system*, and `/run` is a tmpfs that comes up empty
on first boot, so the file would not exist when the unit needs it. The declared
path is therefore `/var/lib/tailscale/authkey`, inside tailscaled's own state
directory.

### D6 — No firewall change

`openFirewall` keeps its `false` default, so within `tailscale0` the host's
reachability is unchanged from the public path: port 22 is already allowed
globally, so SSH over the overlay works without adding a rule. The pinned module
tightens `networking.firewall.checkReversePath` only for `useRoutingFeatures`
values `client`/`both`; this change leaves it at `none`, so the firewall default
stands. Whether strict reverse-path filtering passes overlay traffic on this
host is *not* established by reading the module — the reachability scenario is
what proves it, and the design does not claim it in advance.

### D7 — The auth key carries `tag:server`

Every node in this tailnet is tagged (`nc`, `oci`, `zepyhrus`, `yoga`, `desktop`
— `tailscale status --json`), and the node this change replaces carried
`tag:server`. The key is therefore minted with `tag:server`. If it is minted
untagged instead, the node is owned by the user rather than `tagged-devices` and
any ACL rule written against `tag:server` does not match it — a failure that
looks like tailnet-wide breakage for one host and is diagnosed only by reading
the ACL.

### D8 — The change ships runnable gates, because the host is live and the delivery path is new

The install milestone established that a step which writes to this host gets a
script rather than a paragraph: `scripts/preflight.sh` for gates,
`postinstall-verify.sh` for evidence, `reboot-check.sh` for the deliberate
interruption. This change has the same problem with a worse failure mode — it is
delivered by a path that has never run, to a host whose only other access route is
the one it is adding — so it adds `scripts/tailnet-preflight.sh`,
`scripts/tailnet-verify.sh` and `scripts/tailnet-reboot-check.sh` in the same
three roles.

Two properties are deliberate:

- **`tailnet-verify.sh` decides its own phase.** It reads the host's
  `BackendState` and checks the *pre-enrollment* invariants when the host is not
  `Running`, the *enrolled* ones when it is. It is meant to be run twice, and a
  script that printed a wall of FAILs for the phase it is not in would be worse
  than no script at all.
- **The scripts assert the spec, not the configuration.** The enrolled branch
  checks the node's name, tag, online state and address *as the tailnet reports
  them* — which is the only place the tag exists at all, since it comes from the
  auth key and not from the module.

They are also where this change's two cheaply-learned operational facts get
encoded: the ambient `secretspec` is 0.20.0 while devenv bundles 0.21.0 (so the
scripts invoke the bundled resolver by path), and devenv's `machines info` table
is ANSI-wrapped in a way `NO_COLOR` does not suppress (so the preflight strips
escapes before matching.

### D9 — Host-touching execution happens in a pane, and the wrapper earns its keep

The operator cannot see a `terminal()` call. That is fine for a gate that prints a
verdict in two seconds, and not fine for the two deploys, the enrollment and the
reboot check — the steps where the information that matters is what scrolled past
before the failure. So this change routes them through
`scripts/bb-pane-run.sh`, and makes that a requirement rather than a habit
(`specs/netcup-operations/spec.md`).

Three measured facts shaped the wrapper, and each one was a failure first:

- **A pane does not inherit the invoking shell's environment.**
  `OP_SERVICE_ACCOUNT_TOKEN` is set in the agent's shell and absent in the pane
  (measured 2026-09-27), and because every `devenv machines` invocation resolves
  the whole SecretSpec profile, the preflight fails in a bare pane at its second
  gate. The wrapper exports the token from `~/.config/op-sa-token` (0600) and
  reports only that it did — presence, never value.
- **A pane closes the moment its command exits** (`closeReason:
  "process-exit"`). The first version of this experiment produced a pane that
  vanished before it could be read. The wrapper hands the PTY to a shell
  afterwards, so the output stays.
- **A pane's output is base64** in `bb terminal output --json`, and the session id
  is the only handle on it. The wrapper prints the id *and* the decode command, so
  a result can be re-read rather than re-run.

It also writes the command it is about to hand to the pane into
`$BB_THREAD_STORAGE/panes/`, so "what was that pane doing" is answerable from disk
rather than from memory.

**Rejected:** running the deploys inline and pasting the output afterwards (a
pasted transcript loses the timing, the retries and the ordering — which is the
part worth watching); `herdr pane split` / `herdr pane run` (that splits the
agent's own local terminal, which a remotely-connected bb client cannot see);
and `tee`-ing to a file inside a `terminal()` call (visible only once it is over,
which is the thing being fixed).

### D10 — The enrollment unit is skipped when the key is absent, because a failed unit aborts the deploy

Measured 2026-09-27, on this change's first attempt to deploy itself. The
previous design assumed the pre-enrollment state — the unit looping on the
absent key file until systemd's 90 s start timeout — was an untidy but harmless
intermediate state. It is not: `switch-to-configuration switch` treats a **failed
new unit** as a hard error, prints `warning: the following units failed:
tailscaled-autoconnect.service`, exits 4, and devenv rolls the entire transaction
back (`phase: "rolled-back"`, `previousSystem` restored). The pre-enrollment state
was therefore unreachable, and with it the tailnet.

The decision: pin `ConditionPathExists = "/var/lib/tailscale/authkey"` on the
generated unit, so the absent-key case is a **skip** rather than a failure.

- Measured with a probe unit on this host: a condition-skipped unit reports
  `systemctl start` rc=0, `is-failed: inactive`, `Result=success`,
  `ConditionResult=no` — so it is not counted among failed units and the switch
  proceeds.
- Nothing is lost: the unit still runs at the first boot after an install
  (`install.secrets` writes the key *before* the reboot) and whenever
  `tailnet-enroll.sh` starts it with the key in place.
- The condition is only sound *because* the mechanism declares one path for both
  delivery and reading. If the installation path ever moves, this condition must
  move with it — so `tailnet-preflight.sh` greps the built unit for it, in the
  same gate that greps for the module's `ExecStart` script and `--hostname`.
- The evidence for the pre-enrollment state changes with it: it is
  `ConditionResult=no`, not a journal line about the missing key, because a
  skipped unit never runs and never logs.

This is the change's clearest example of the gates earning their keep: the failure
is invisible in a config diff and in a `switch-to-configuration` exit code read
from the workstation, and would have been diagnosed as "the deploy path is
broken" without the journal from the host.

## Risks / Trade-offs

- **The delivery mechanism is unproven.** `deploy` has never run on this host
  (`phase: "uninitialized"`), and this change asks it to carry a new systemd unit
  and a secret file. Mitigation: the first deploy task carries the *current*
  configuration unchanged, so a deploy failure is attributable to the deploy path
  rather than to tailscale — and the tailnet change is only added after that
  deploy is observed to succeed.
- **A host-key change breaks a future install's local secret delivery.** Once
  `install.secrets` is declared, an install must pin the host keys of both the
  original OS and the kexec installer, and a re-image replaces the host key.
  This does not affect this change's live path (nothing local is sent by
  `deploy`), but it is a real prerequisite the next install will meet, and the
  mechanism for satisfying it — a dedicated
  `UserKnownHostsFile`, preloaded — is not yet designed.
- **Strict reverse-path filtering.** See D6: unverified, and the reachability
  scenario is the gate.
- **The vault is now on the path to inspecting the machine.** Accepted in D2,
  and it is the one cost that will be felt daily.
- **The auth key at rest.** Bounded by `0600 root:root` and by the key's own
  scope; not bounded by anything this repository controls if the host is
  compromised.
- **Key expiry.** The node this change replaces was created with
  `KeyExpiry` set six months out (`2027-03-26`), so this tailnet does apply
  expiry. A node whose key expires drops off the tailnet until re-authenticated;
  with `authKeyFile` in place a reboot should recover it, but that recovery path
  is untested here.
- **A failed unit is not merely untidy — it aborts the deploy. (Superseded by
  measurement 2026-09-27; see D10.)** This bullet previously called the
  pre-enrollment failure harmless. It is not harmless: `switch-to-configuration`
  exits 4 on a failed new unit and devenv rolls the transaction back, which made
  the pre-enrollment state unreachable. Mitigated by the `ConditionPathExists`
  decision in D10, so the state is now a *skip*. The misreading risk described
  here was real and is closed differently than planned: `tailnet-verify.sh`'s
  pre-enrollment branch asserts `ConditionResult=no` rather than a journal line,
  because a skipped unit never runs and therefore logs nothing about the key.
- **Node-name collision — closed, but kept as a gate.** The stale node was
  deleted 2026-09-27 and its absence is verified, so the name is free. It stays a
  preflight check rather than a historical step because a node reappearing between
  now and the enrollment would push the new one to `nc-1`, which the requirement
  forbids — and that is exactly the kind of thing that happens months later and is
  diagnosed as "the config is broken".

## Migration

1. ~~Delete the stale `nc` node from the tailnet.~~ **Done 2026-09-27**, verified
   from the workstation: nine peers, none named `nc`. Kept as a preflight gate
   rather than a completed step, because anything that joins the tailnet before
   this change enrolls takes the name out from under it.
2. Mint a `tag:server`, reusable auth key; store it as `TS_AUTH_KEY` in the
   `dev` vault; verify with `op item list --vault dev` and
   `secretspec check --no-prompt --json`.
3. Land the repository changes and confirm they evaluate —
   `scripts/tailnet-preflight.sh` is this step and the next one in one command.
4. **No-op deploy of the current configuration, to prove the deploy path.** Its
   own step, before tailscale is in the configuration, so a failure is
   attributable to the deploy rather than to the change.
5. Deploy the tailnet change. The host comes up with tailscaled running,
   unenrolled, and public SSH intact — a state with no way to lose access.
   `scripts/tailnet-verify.sh` asserts precisely that state. **This step failed
   on its first attempt** and was rolled back by devenv: with the key absent the
   generated unit *failed*, and a failed new unit aborts `switch-to-configuration`
   (exit 4). It only became reachable once the unit was made to skip instead —
   D10, which is the decision this step forced.
6. Populate `/var/lib/tailscale/authkey` on the host from the vault, then start
   `tailscaled-autoconnect.service` and watch it enroll.
7. Verify from the workstation with `scripts/tailnet-verify.sh`, interrupt the
   host deliberately with `scripts/tailnet-reboot-check.sh`, then reconcile the
   docs.

Steps 5 and 6 are ordered so that the host is never in a state where the change
has removed an access path and not yet added one. That property is what makes the
whole sequence safe to run against a live host, and it is why the change does not
fold the enrollment into the deploy.

## Open Questions

1. **Auth key shape — STILL OPEN, and not answerable from this repository.**
   Reusable, or single-use? Reusable is what makes a
   re-image self-enrolling for the key's lifetime; single-use is a smaller
   standing credential. And what expiry, given a re-image after the expiry fails
   to enroll? This is the operator's call and it changes nothing in the
   configuration — only the console action in task 1.3.
2. **Does the key stay at rest?** This design says yes, because removing it
   after enrollment would leave the host unable to re-enroll from its own
   configuration. An alternative is to remove it and accept that a host whose
   node key is invalidated needs a manual step; that trades a standing credential
   for a recovery step.
3. **Should `nc` be exempted from key expiry?** This tailnet applies expiry to
   tagged nodes (measured on the node being replaced). Exempting `nc` makes the
   overlay a property that does not lapse; not exempting it means the
   `authKeyFile` path is what rescues the host, which is also a fair test of it.
4. **Is carrying `install.secrets` in *this* change right, when its execution
   cannot be verified until the next re-image?** The alternative is a narrower
   change — enable tailscale, populate the path by hand, no manifest — followed
   by a second change that adds SecretSpec once a re-image is actually on the
   table. This change takes the wider scope because the vault item and the
   declared name are wanted now and the configuration is otherwise identical;
   the reviewer may reasonably decide the unverifiable part should not be
   declared until it can be tested.
5. **Is the vault-on-every-`machines`-command coupling acceptable permanently?**
   ADR-0006 F5 worked around it with `SECRETSPEC_PROVIDER=file:<dir>`, noting
   that the override also overrides per-secret `providers` pins. If that
   coupling becomes painful, the workaround is a known escape hatch with a known
   sharp edge.

## Gates

Each requirement, and the command that proves it. The scripts are the executable
form of the tasks file, so most rows name a script and then the primitive it
actually runs.

| Requirement | Proven by |
|---|---|
| The tailnet node name is declared, not inherited | `scripts/tailnet-preflight.sh` step 7 — `cat $SYS/etc/hostname` is `netcup` while the generated `tailscaled-autoconnect.service` contains `--hostname=nc`; then `tailscale status --json`'s peer record |
| The pre-enrollment state is deployable at all (D10) | `scripts/tailnet-preflight.sh` step 7 greps the *built* unit for `ConditionPathExists=/var/lib/tailscale/authkey`; on the host, `scripts/tailnet-verify.sh` asserts `ConditionResult=no` and `is-failed: inactive` — a *skipped*, not failed, unit |
| The host enrolls from its own configuration | preflight steps 4, 4c, 6 and 7 — the declared `authKeyFile` string as it appears in the script `ExecStart` points at, `devenv eval machines.netcup.install.secrets`, and a sweep of the built system for the value; `scripts/tailnet-verify.sh`'s enrolled branch and `scripts/tailnet-reboot-check.sh` for the behavior |
| No auth key value is stored in the repository or the Nix store | preflight step 7's sweep (pattern on stdin, never argv); `secretspec check --no-prompt --json`; `grep -r` of the repository |
| Exactly one node named nc exists in the tailnet | preflight step 5 (the name is free); `scripts/tailnet-verify.sh`'s enrolled branch asserts one node, its `DNSName`, `Online` and tags, and that its record is new |
| The host is reachable over the overlay without weakening the public path | `scripts/tailnet-verify.sh` and `scripts/tailnet-reboot-check.sh` — SSH over `nc.worm-hue.ts.net` as operator and root, MagicDNS resolution, `tailscale ping`, and the public address still answering; preflight step 8 for the firewall facts |
| *netcup-machine*: the Machine evaluates | `devenv eval machines.netcup.build.nixos`, and `devenv machines info` with and without a vault session (tasks 4.1 and 4.6) |
| *netcup-operations*: host-touching commands are watchable | every host-touching task in `tasks.md` names `./scripts/bb-pane-run.sh`, and `bb terminal list --thread $BB_THREAD_ID` shows the sessions it created; a local half-second `devenv eval` stays inline, which is what keeps the rule about visibility rather than ceremony |
| *netcup-operations*: the wrapper establishes the pane's environment | `scripts/bb-pane-run.sh` reports the token export in the pane, and the preflight's second gate — which cannot pass without the vault — passes there; `tailnet-enroll.sh` fails if a key-shaped string reaches the journal |
| *netcup-operations*: the command is recorded | `$BB_THREAD_STORAGE/panes/*.sh` holds the command, and re-running it reproduces what the pane did |

A note on read-back: `machines.netcup.build.nixos` is a store path string, and
`devenv eval` exposes `deploy.*` and machine metadata as attributes — it does not
serialise the NixOS module functions. The evaluated NixOS configuration is
therefore read from the built system's own `/etc` (`$SYS/etc/systemd/system/`,
`$SYS/etc/hostname`, `$SYS/etc/ssh/sshd_config`).
