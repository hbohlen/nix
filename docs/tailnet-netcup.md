# netcup and the tailnet

Written 2026-09-27 by the change `add-netcup-tailnet`. This is the procedure of
record for a **live** host: what `nc` is, how it enrolls, how to check it, and
the failures that cost real time. The install-time half of the same mechanism
(`install.secrets`) cannot be exercised until the next re-image — see "Not
verified by this change" at the end, which is the honest boundary of this page.

---

## 1. The node

| | |
|---|---|
| Tailnet | `hbohlen.github` |
| MagicDNS suffix | `worm-hue.ts.net` |
| Node name | `nc` (DNSName `nc.worm-hue.ts.net`) |
| Tag | `tag:server` — from the auth key, not from the config |
| Tailnet address | `100.95.168.15` (stable across two reboots, 2026-09-27) |
| Node id | `nodekey:f5b32eeefc6586dd801dcf70b55bd83ac160303fdbd69ec6b9a6d768ba1fa80f` |
| Enrolled | 2026-09-27T17:22:36Z, through `tailscaled-autoconnect.service` |
| Public path | `152.53.92.126`, port 22 — still open, unchanged by this change |

The node name is pinned in the configuration with `extraUpFlags =
[ "--hostname=nc" ]`, deliberately **not** by renaming the host:
`networking.hostName` stays `netcup`, so the prompt, the journal identifier, the
DHCP identity and the `nixos-system-netcup-*` derivation name are untouched. The
old node `nc` (`100.95.92.47`, the wiped Debian install) was deleted before
enrollment; the current node is new — `Created` 2026-09-27T17:22:36Z, and the
deleted node's id is absent from `tailscale status --json`.

## 2. How the host enrolls

The key is delivered to a host path and read from that same path by a unit the
pinned tailscale module generates:

```
install.secrets[name == "/var/lib/tailscale/authkey"]   (first boot after install)
        └─> /var/lib/tailscale/authkey  (0600 root:root)
                └─> services.tailscale.authKeyFile
                        └─> systemd.services.tailscaled-autoconnect  → tailscale up
```

`/var/lib/tailscale`, not `/run`, because `install.secrets` writes after
`nixos-install` and before reboot: a tmpfs path would be empty at the very first
boot that needs it.

**The path is a plain string, never a Nix path literal.** `authKeyFile` is
`types.path`, which an absolute string satisfies — and a path *literal* would be
copied into the world-readable store. `scripts/tailnet-preflight.sh` compares the
string against the `install.secrets` attribute name so the two cannot drift.

### The unit is skipped when there is no key, and that is load-bearing

```nix
systemd.services."tailscaled-autoconnect".unitConfig.ConditionPathExists =
  "/var/lib/tailscale/authkey";
```

Without that condition the change **cannot be deployed at all**. Measured the
hard way on 2026-09-27: with the key absent — the pre-enrollment state this
change deliberately passes through — the generated unit loops, hits
`cat: /var/lib/tailscale/authkey: No such file or directory`, and is killed by
its 90 s start timeout. A *failed* new unit makes `switch-to-configuration switch`
exit 4 (`warning: the following units failed:
tailscaled-autoconnect.service`), and devenv then rolls the entire transaction
back (`phase: "rolled-back"`, `previousSystem` restored). The first attempt at
deploying this change ended exactly there.

`ConditionPathExists` turns the absent-key case into a **skip**. Measured with a
probe unit on this host: a condition-skipped unit reports `systemctl start`
rc=0, `is-failed: inactive`, `Result=success`, `ConditionResult=no` — so it is
not counted among failed units and the switch proceeds. The unit still runs in
every state that needs it: at the first boot after an install, and whenever
`scripts/tailnet-enroll.sh` starts it.

The consequence for anyone reading a verifier: **pre-enrollment, the unit is
skipped and the journal says nothing about the missing key** (it never ran). The
evidence is `ConditionResult=no`, not a log line. A journal line about the
absent key belongs to the rolled-back first attempt, not to a healthy host.

## 3. Enrolling a live host (the procedure of record)

One visible command, from the repository root:

```bash
./scripts/bb-pane-run.sh --title "enroll nc" -- ./scripts/tailnet-enroll.sh
```

It is its own script because it is the step with no rollback and it moves a
credential. What it does, all of it visible in the pane: confirms the target and
that the host is not already enrolled; resolves `TS_AUTH_KEY` through **devenv's
bundled** resolver (not the ambient 0.20.0); streams the value into
`/var/lib/tailscale/authkey` over the ssh channel **on stdin** — never argv,
never a local file; applies `chmod 0600` and `chown 0:0`; restarts
`tailscaled-autoconnect`; waits for `BackendState=Running`; prints the unit's
`Result` and this boot's journal; and fails outright if a key-shaped string
reached the journal. On 2026-09-27 it reported `ENROLLED` after `Running in 2s`.

### The key's life at rest

**Decision taken: the key is left on the host** (the script's default — measured
after enrollment: `/var/lib/tailscale/authkey`, mode `0600`, `root:root`). That
is what keeps a future re-image self-enrolling, and it is the same file
`install.secrets` will write on the next install. `--remove-key` takes it off the
host instead, at the cost that a host whose node key is invalidated can then only
re-enroll during an install.

Note the key is **not** needed on subsequent boots: this boot's journal contains
no `sending auth key`, because `tailscaled` persists its node key in
`/var/lib/tailscale` and comes back `Running` by itself. The auth key is
load-bearing at *enrollment*, not at runtime — that is what the reboot check
exists to prove.

### The auth key's shape, and what is NOT recorded

| | |
|---|---|
| Vault item | 1Password `dev` vault, `TS_AUTH_KEY` (`API_CREDENTIAL`) |
| SecretSpec field | `credential` — **not** `password`; the item's concealed field is labelled `credential` |
| Resolved length | 61 bytes (a `tskey-auth-…` string) |
| Expiry / single-use | **NOT RECORDED — and not readable from here.** |

The expiry and the reusable-vs-single-use choice are properties set in the
Tailscale admin console when the key is minted; neither the vault item nor the
host carries them, and nothing in this repository can observe them. The item
holds no metadata about them (its `notesPlain` and `username` fields are empty).
**This is the one thing task 7.2/9.1 must record that could not be measured:**
whoever next mints a key should write its expiry and type here in the same
commit. Until then, treat the key as unknown-lifetime and do not assume a failed
enrollment can be retried with the same key.

## 4. Checking it — the four tailnet scripts

These sit beside the three install scripts (`preflight.sh`,
`postinstall-verify.sh`, `reboot-check.sh`) and are meant to be invoked through
`./scripts/bb-pane-run.sh`, never as a bare agent tool call: the operator watches
a host-touching step rather than trusting a summary of it.

| Script | When | Says what |
|---|---|---|
| `tailnet-preflight.sh` | before any host contact | 9 gates, no host contact: config, build, the generated unit, and a sweep proving no auth key value is in the Nix store |
| `tailnet-verify.sh` | after the deploy, and after enrollment | branches on `BackendState`: `PRE-ENROLLMENT CHECKS PASSED` or `ALL TAILNET CHECKS PASSED` |
| `tailnet-enroll.sh` | once, to enroll a live host | see §3 |
| `tailnet-reboot-check.sh` | last | **reboots the host** and proves it rejoins unattended |

**`tailnet-preflight.sh` is a *pre*-enrollment gate, and it is expected to fail at
gate 5 ("the name `nc` is free") from the moment the host is enrolled** — the
enrolled host *is* the node named `nc`. Nothing it can see distinguishes "the
host this change enrolled" from "a stale or competing registration" (that needs
host contact, which the preflight deliberately does not do), so it fails loudly
and explains both cases. Its job is the *fresh* enrollment case — a re-image or a
second host — where an old registration would push the new node to `nc-1`. To
check a live enrolled host, use `tailnet-verify.sh`; delete the `nc` node only
when a re-image makes a fresh enrollment necessary.

The reboot check decides whether this change bought what it claims. A passing run
on 2026-09-27 (third attempt — see §5): public path back after 22 s, overlay
after 25 s, new boot id, `BackendState: "Running"`, autoconnect `Result=success`,
no `sending auth key` in that boot, address unchanged at `100.95.168.15`.

## 5. Measured facts that cost a failure

Every item here is a real defect or a real trap from this change. None is
guessable from the docs.

- **`timeout` cannot call a shell function.** `timeout 15 rsh …` never ran `rsh`
  at all — `timeout` is an external binary, so it exits 127 with
  `timeout: failed to run command 'rsh': No such file or directory`. With stderr
  sent to `/dev/null` the reboot check's wait loop read that as "the host is not
  back yet", so the public path could *never* be detected as back and the check
  reported a false negative on a host that was down for **ten seconds**
  (previous boot ended 17:30:18, next began 17:30:28, sshd active 17:30:32 — and
  the check still failed after 410 s). The timeout now belongs inside the ssh
  invocation, and the loop fails loudly on rc=127 instead of treating a broken
  probe as an unreachable host. `scripts/reboot-check.sh:29` had it right.
- **The host has no `python3`.** It is a minimal NixOS. Running
  `tailscale status --json | python3 -c …` *on the host* fails with
  `bash: line 1: python3: command not found`, which surfaced as a failed
  `BackendState` assertion on a host that was demonstrably Running. Parse the
  host's JSON on this side of the ssh (`tailnet-verify.sh:70`) or with grep.
- **A failed systemd unit aborts a deploy.** See §2 — `switch-to-configuration`
  exits 4 and devenv rolls back. Any unit this host declares must be able to
  succeed, or be skipped, in every state the host legitimately passes through.
- **`devenv machines deploy` stops at `Apply this fleet plan? [y/N]`.** In a pane
  nothing will type the answer, so pass `--yes`. Same class of trap as
  `--no-tui`: invisible in a non-TTY tool call, fatal where a human is watching.
- **`scripts/bb-pane-run.sh` wrote its command as `cmd=word word word`,** which
  bash does not read as a multi-word assignment — it is an assignment prefix on
  the command `word`, so a multi-word command was swallowed and `eval "$cmd"`
  then evaluated the empty string and reported **exit 0**. A pane that ran
  nothing looked like a success. Single-word commands (`…/tailnet-preflight.sh`)
  hid it for the whole gate phase. The command is now a `%q`-quoted array.
- **The Machine's effective nixpkgs** is `cachix/devenv-nixpkgs@c2f38fe7…` →
  `NixOS/nixpkgs@c7def046…`, with patches that do not touch tailscale or systemd
  (they are poetry, lean4 and llvm-darwin).
- **`require_reason = true` costs every `devenv machines …` command an
  environment variable.** devenv forwards no reason flag, so `SECRETSPEC_REASON`
  must be set or the command dies with "Accessing secrets requires a reason".
  The scripts and the pane wrapper export it; hand-typed commands do not get it
  for free. Once a `secretspec.toml` exists, **every** `machines` invocation —
  read-only `info` included — resolves the whole profile and therefore needs the
  vault reachable. That is the price of putting the key on the install path, paid
  deliberately.
- **The ambient `secretspec` is a different version from devenv's bundled one**
  (0.20.0 vs 0.21.0). Use the bundled resolver by path.
- **A systemd unit's script body is not in the unit file.**
  `systemd.services.<name>.script` builds to its own store path; the unit holds
  only `ExecStart=…/unit-script-<name>-start/bin/<name>-start`. Grepping the unit
  for a string from the script fails on a correct configuration.
- **devenv renders a progress TUI whenever stdout is a TTY**, which floods a bb
  pane (measured: 664,766 characters for one build, almost all spinner frames).
  Pass `--no-tui` in a pane.
- **A bb terminal pane inherits neither `OP_SERVICE_ACCOUNT_TOKEN` nor
  `BB_THREAD_ID`**, and its session closes the instant its command exits. The
  generic technique is in the `bb-terminal-pane` skill.
- **`devenv machines info` output is ANSI-wrapped** and `NO_COLOR` does not
  suppress it; strip escapes before matching on it.
- **The `dev` vault's service account is read-only, and secretspec resolves a
  field by the label the item actually has.** The auth key's concealed field is
  `credential`. `op item get --format json` prints concealed values — filter it,
  never run it bare.
- **Local install payloads require pre-pinned host keys** — for the original OS
  *and* the kexec installer when they differ.

## 6. Not verified by this change

- **The `install.secrets` half of the enrollment mechanism has not been
  exercised.** It cannot be: it runs between `nixos-install` and reboot. The live
  host was brought to the same state by `tailnet-enroll.sh` instead, which is the
  *same* unit reading the *same* path — so what is unproven is the delivery, not
  the enrollment. The next re-image is the first real test of it.
- **The auth key's expiry and reusable-vs-single-use shape** — §3. Console-side,
  not readable from the repository or the host.
