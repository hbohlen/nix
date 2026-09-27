## Why

netcup has exactly one access path: key-only SSH on the provider-assigned public
address `152.53.92.126`. It is the only host in this operator's tailnet whose
reachability depends on that address staying routed and unblocked, and it is the
only host that cannot be reached from a network that filters it.

It is also on the critical path of the change that follows. The follow-ups hand
off closing root login, and a configuration that closes public SSH is only
survivable if the overlay comes up **unattended, on the first boot after an
install** — because the rebooted system would have no public SSH left to dial.
No mechanism in this repository provides that today, so without this change the
hardening change cannot be written at all.

The name it will take, `nc`, was held by the *previous* netcup host — the Debian
install this repository replaced — and that node has been removed, so the name
is free:

```
$ tailscale status --json     # from the operator workstation (node `contabo`)
peer nc: ID nwjHjrxuF521CNTRL, DNSName nc.worm-hue.ts.net., Tags ["tag:server"],
         Created 2026-09-27T04:31:08Z, LastSeen 2026-09-27T13:10:00Z,
         Online false, KeyExpiry 2027-03-26T04:31:08Z
```

That was one of the two prerequisites this change needs from outside the
repository; removing it was manual because the workstation's CLI cannot delete
another node. `scripts/tailnet-preflight.sh` re-checks the name is free on every
run, because Tailscale deduplicates node names — a node that reappears would
silently become `nc-1` and this change's milestone would quietly not be met.

**Milestone advanced:** netcup is a member of the `hbohlen.github` tailnet under
the MagicDNS name `nc` (`nc.worm-hue.ts.net`), with the node identity and the
enrollment declared in this repository rather than performed by hand.

## What Changes

- **New:** `services.tailscale` enabled on the host, with the node name pinned
  to `nc` so it is independent of the host's own `networking.hostName`
  (`netcup`, which stays as it is).
- **New:** the auth key delivered to a declared host path, consumed by the
  pinned module's `tailscaled-autoconnect.service`. This is the mechanism that
  makes enrollment a property of the machine instead of a step in an operator's
  shell session.
- **New:** the repository's first `secretspec.toml`, declaring `TS_AUTH_KEY`
  against the 1Password `dev` vault, plus the `secretspec` block in
  `devenv.yaml` that makes local execution possible and the
  `machines.netcup.install.secrets` mapping that writes the value on an install.
- **New:** a `netcup-tailnet` capability and a procedure document recording the
  tailnet facts — tailnet `hbohlen.github`, MagicDNS suffix `worm-hue.ts.net`,
  node name `nc`, tag `tag:server`.
- **New:** a three-script verification suite, in the shape the install milestone
  established — `scripts/tailnet-preflight.sh` (gates, writing nothing to the
  host), `scripts/tailnet-verify.sh` (read-only evidence, and honest about which
  phase it is looking at), and `scripts/tailnet-reboot-check.sh` (the deliberate
  interruption that proves the host rejoins the tailnet without needing the key
  again). This change is delivered to a *live* host by a mechanism — `deploy` —
  that has never run here, so the gates are the artifact, not a convenience.
- **New:** a `netcup-operations` capability and `scripts/bb-pane-run.sh`, which
  establishes **how** this change's host-touching steps are executed: in a bb
  terminal pane the operator can watch, rather than as detached commands whose
  results are reported afterwards. The deploy, the enrollment and all four
  verification scripts are routed through it. Two measured facts forced the
  wrapper to exist: a pane does not inherit the invoking shell's environment (in
  particular `OP_SERVICE_ACCOUNT_TOKEN` is absent, and every `devenv machines`
  invocation resolves the whole SecretSpec profile), and a pane closes the instant
  its command exits, so a script that prints and returns is unreadable.
- **New:** `scripts/tailnet-enroll.sh`, because the enrollment turned out to be
  two shell invocations plus a process substitution rather than one command —
  the shape that gets mistyped — and it is the step that carries a credential.
- **Modified:** `netcup-machine`'s requirement that evaluation needs no secret
  provider. It stops being true, deliberately: with a manifest in the tree,
  inspecting the machine becomes a vault-privileged action.
- **Not in this change:** closing root login or changing `PermitRootLogin`;
  confining sshd to the overlay interface; MagicDNS as the host's resolver;
  Tailscale SSH; exit nodes, subnet routers, `tailscale serve`/`funnel`; ACL or
  session-recording changes; sops-nix or agenix; and any firewall change —
  `services.tailscale.openFirewall` keeps its default `false`, so this change
  adds no port and the machine's "only the SSH port is exposed" property holds.
- **Dropped relative to `~/projects/nixos`:** the Proton Pass manifest and its
  `nixos/default/<KEY>` note-mirror items. The mirrors existed only because the
  protonpass provider cannot address a field; the 1Password provider addresses
  an item and a field directly, verified against this vault (see design).
- **Inherited idea, re-earned rather than copied:** ADR-0006 in
  `~/projects/nixos` hypothesised that `install.secrets.TS_AUTH_KEY` feeding the
  path the tailscale module reads is what retires a staged bootstrap. It is
  cited here as a hypothesis that this change tests, not as a decision it
  inherits — the payoff is now different, because this root has no staged
  bootstrap to retire.

## Capabilities

### New Capabilities

- `netcup-tailnet`: netcup's membership in the tailnet — the declared node
  identity and name, the mechanism that enrolls it without an operator session
  at the console, and the evidence that it is reachable over the overlay.
- `netcup-operations`: how this repository executes the commands that touch the
  host — that they are watched while they run, that the wrapper establishes the
  environment a pane needs, and that what a pane was asked to run is recorded.

### Modified Capabilities

- `netcup-machine`: the scenario *Evaluation requires no secret provider* under
  **The Machine evaluates to a bootable NixOS system** states that evaluation
  succeeds on a workstation with no vault session and no `secretspec.toml`.
  This change puts a `secretspec.toml` in the tree, so that scenario becomes
  false. The requirement itself is not being abandoned — evaluation still needs
  to succeed, and still needs to be the thing that proves the system builds —
  but its precondition changes from "no vault" to "the vault resolves".

## Impact

- **Repository:** adds `secretspec.toml`, `hosts/netcup/tailnet.nix`,
  `scripts/tailnet-{preflight,verify,reboot-check,enroll}.sh`,
  `scripts/bb-pane-run.sh`, and `docs/tailnet-netcup.md`; modifies `devenv.nix`
  (the `install.secrets` mapping), `devenv.yaml` (the `secretspec` block), and
  `hosts/netcup/default.nix` (the module import). The capability specs land under
  `openspec/specs/{netcup-tailnet,netcup-operations}/` when this change is
  archived.
- **Toolchain:** SecretSpec `0.21.0`, already bundled in the pinned devenv
  (`/nix/store/axhrys71dyh0l7gynicv8mfy9y9mjc4i-devenv-wrapped-2.4.0/bin/secretspec
  --version`). No new input and no new package.
- **Vault:** a new `TS_AUTH_KEY` item in the `dev` vault, holding a Tailscale
  auth key. The value is minted in the Tailscale admin console — it is not
  produced by this repository.
- **Tailnet:** the stale `nc` node has been deleted (verified 2026-09-27), so the
  name is free for the first enrollment. A node that reappears before enrollment
  would push the new one to `nc-1`; the preflight gate checks for that.
- **Host:** a new `tailscale0` interface, the `tailscaled` and
  `tailscaled-autoconnect` units, and one secret file at rest.
- **Workstation:** with a manifest in the tree, **every** `devenv machines`
  invocation — read-only `info` included — resolves the whole SecretSpec
  profile, so the vault becomes a prerequisite for inspecting the machine. This
  is measured behaviour, not a prediction: ADR-0006 F5 in `~/projects/nixos`
  records a read-only `devenv machines info` refusing to run until every
  declared secret resolved, and `devenv.yaml` here carries the same note from
  the other direction.
- **Not destructive to the disk.** This change is delivered by `devenv machines
  deploy`, not `devenv machines install`, so no re-image is required. That path
  has never run on this host — `devenv machines status netcup` reports
  `{"phase": "uninitialized"}` — and the change schedules a no-op deploy before
  it as its own task rather than discovering that mid-change.
- **Authentication:** unchanged. The operator's ed25519 identity is still the
  1Password `dev` vault item `SSH Key`, materialized per use; the new auth key
  is a separate credential in the same vault and never reaches the repository or
  the Nix store.
- **Pre-existing, not this change's:** `devenv machines check netcup` reports
  `Warning [access-analysis-incomplete]: Dynamic key sources or custom
  SSH/firewall configuration require manual review`. That warning comes from the
  host's `dynamicKeys = true` SSH facts and is unrelated to this change; it is
  recorded here so the next reader does not attribute it to the tailnet work.
