## 0. The verification suite (no host contact)

Written first, because every group below names the script that runs it. The
scripts are the executable form of this file, in the same shape as
`scripts/preflight.sh` / `postinstall-verify.sh` / `reboot-check.sh`.

**Execution policy — this file routes through a bb terminal pane.** Every task
below that touches the host, or that runs one of this repository's scripts, is
run with `./scripts/bb-pane-run.sh …` so the operator watches it happen in the bb
app instead of being handed a result after the fact. Local one-line `devenv eval`
commands stay inline, because a pane for a half-second eval is noise. The policy
is a requirement, not a style note: see
`specs/netcup-operations/spec.md`.

`bb-pane-run.sh` exports `OP_SERVICE_ACCOUNT_TOKEN` from `~/.config/op-sa-token`
before the command runs, because the pane does **not** inherit this shell's
environment and every `devenv machines` invocation resolves the whole secretspec
profile (measured 2026-09-27: the token is set in the agent's shell, absent in the
pane, and `devenv machines info` fails there without it).

- [x] 0.1 Four scripts exist, are executable, and parse:
  ```
  bash -n scripts/tailnet-preflight.sh scripts/tailnet-verify.sh \
           scripts/tailnet-reboot-check.sh scripts/tailnet-enroll.sh
  ```
  **Done 2026-09-27.** All pass `bash -n` and are mode 755. `tailnet-enroll.sh`
  was added after the first three, when task 7 turned out to be two shell
  invocations plus a process substitution rather than one command.
- [x] 0.2 Each script has been run against the repository at least once, so its
  failure messages are known to be the actionable ones rather than a stack of
  noise. **Verify:** `./scripts/tailnet-preflight.sh` on the current tree fails
  at step 3 with `no TS_AUTH_KEY item in the dev vault`, which is the correct
  answer until 2.1 lands. A run that gets further than that before the vault
  item exists means a gate is not actually gating.
  **Partially done 2026-09-27:** steps 1, 2, 3, 5 and 8 have been exercised
  against the live tailnet and the current tree (step 2 needed an ANSI-strip
  fix, which the run found; step 5 confirms `nc` is free; step 8's fact parse
  returns its expected verdict). Steps 4, 6 and 7 cannot run until 3.1–3.3
  land, and the store sweep's detection was proven separately with a positive
  control.
- [x] 0.3 The pane runner exists and has been exercised end to end.
  **Verify:**
  ```
  ./scripts/bb-pane-run.sh --title "tailnet preflight" -- ./scripts/tailnet-preflight.sh
  ```
  **Done 2026-09-27.** The pane printed
  `[bb-pane] OP_SERVICE_ACCOUNT_TOKEN exported from ~/.config/op-sa-token`, ran
  gates 1–3, failed at gate 3 with the correct message, reported
  `exit 1 after 0s`, and stayed open for reading. The same run is what
  established that a pane cannot reach the vault unaided — the first attempt,
  with no token export, is why the wrapper does it.
  **CAVEAT, added 2026-09-27 during execution: this task was ticked too early.**
  That run used a *single-word* command, and the wrapper was broken for any
  multi-word command — it wrote `cmd=word word word`, which bash reads as an
  assignment prefix on the command `word`, so the command never ran and `eval`
  of the empty string reported **exit 0**. The first real multi-word pane (the
  no-op deploy, task 5.1) printed `line 15: machines: command not found` and
  `exit 0` — a pane that ran nothing, looking like a success. Fixed by writing
  the command as a `%q`-quoted array plus a guard. "Exercised end to end" means
  exercised *with the argument shapes the change actually uses*, not once with a
  convenient one.

## 1. Tailnet prerequisites (no host contact)

- [x] 1.1 Record the tailnet's membership before changing anything, and confirm
  which node held the name `nc`:
  ```
  tailscale status
  tailscale status --json > /tmp/tailnet-before.json
  ```
  **Done 2026-09-27.** The peer was `nc`, ID `nwjHjrxuF521CNTRL`, DNSName
  `nc.worm-hue.ts.net.`, `TailscaleIPs` `100.95.92.47`, `Tags` `["tag:server"]`,
  `Online` false, `Created` `2026-09-27T04:31:08Z`, `LastSeen`
  `2026-09-27T13:10:00Z`, `KeyExpiry` `2027-03-26T04:31:08Z`. That last field is
  why design open question 3 exists: this tailnet applies key expiry to tagged
  nodes.
- [x] 1.2 Delete the stale `nc` node from the tailnet.
  **Done 2026-09-27 by the operator** (admin console → Machines → `nc` → Remove
  device). The CLI on this workstation cannot remove another node, so this step
  is manual.
  **Verified 2026-09-27** on this workstation: `tailscale status` lists nine
  peers and none is `nc`; `tailscale status --json` contains no peer whose
  `HostName` is `nc` or whose `DNSName` begins `nc.`. The name is free.
  `scripts/tailnet-preflight.sh` step 5 re-checks this on every run.
- [x] 1.3 Mint a Tailscale auth key in the admin console with tag `tag:server`
  and the shape decided in design open question 1 (reusable vs single-use,
  expiry). Do not display it.
  **DONE 2026-09-27 by the operator** (the value is in the vault as task 2.1).
  The tag and expiry are **not** verifiable from this side: they are properties of
  the key in the tailnet's admin console, and the vault item holds only the value.
  The tag is asserted where it can actually be observed — task 8.2 reads the
  enrolled node's `Tags` from `tailscale status --json` — and the expiry decision
  belongs in `docs/tailnet-netcup.md` alongside the answer to open question 1.
  That the value is an *auth* key rather than an API key or OAuth client is
  verified: `scripts/tailnet-preflight.sh` gate 4b measures `prefix=tskey-auth-`.

## 2. Vault item (no host contact)

- [x] 2.1 Create the `TS_AUTH_KEY` item in the 1Password `dev` vault.
  **DONE 2026-09-27 by the operator**, after the agent established it could not be
  done from here — see the read-only note at the end of this task.
  **The item as it actually exists, measured, and it differs from what this file
  first assumed:** category `API_CREDENTIAL` (not Password), id
  `zw52okha5l4e4cpjlgmp2pvwmq`, and the concealed field's id and label are **both
  `credential`** — there is no `password` field. The manifest must therefore
  address it as `ref = { item = "TS_AUTH_KEY", field = "credential" }`. The guessed
  `field = "password"` fails with
  `item 'dev/TS_AUTH_KEY' does not have a field 'password'` (measured; a probe
  manifest carrying both spellings proved the negative case as a control).
  **Verified 2026-09-27** with devenv's bundled resolver against a throwaway
  manifest: `status: resolved`, and the value measures
  `len=61 prefix=tskey-auth-` — non-empty, and the auth-key kind rather than an API
  key or an OAuth client secret. `API_CREDENTIAL` fits an auth key better than
  Password does, so the item is left exactly as the operator created it.
  **Verify / re-verify:**
  ```
  op item list --vault dev            # titles only
  ./scripts/tailnet-preflight.sh      # gates 3, 4 and 4b, once task 3.1 lands
  ```
  Gate 4 alone is not enough: `secretspec check --json` is value-free, so an item
  that exists with an **empty** field still reports `resolved`. Gate 4b measures
  the value and fails on an unfilled placeholder — which is the state this item
  would have been in had it been created empty, as was the original plan.
  Never run `op item get TS_AUTH_KEY --vault dev --format json` bare: it prints the
  value. `scripts/tailnet-preflight.sh` step 3 is the title-only half.
  **Why this was an operator action (measured 2026-09-27):** the `dev` vault's
  service-account token is **read-only**. `op item create` returns
  `(101) You do not have permission to perform this action` for every category
  tried (Password, Secure Note) and both vault-addressing forms (`--vault dev`,
  `--vault <id>`), while `op item get` and `op item list` succeed. Granting the
  service account Read+Write would let an agent do it, but that widens a credential
  this repository otherwise only reads with, so it stays a decision rather than a
  convenience.

## 3. Repository changes (no host contact)

- [x] 3.1 Add `secretspec.toml` at the repository root.
  **Done 2026-09-27.** `[project]` name/revision with `require_reason = true`,
  `[providers.dev] uri = "onepassword+token://dev"`, and a `[profiles.default]`
  entry declaring `TS_AUTH_KEY` with
  `ref = { item = "TS_AUTH_KEY", field = "credential" }` — `credential`, not
  `password`: the operator's item is an `API_CREDENTIAL` whose concealed field is
  labelled `credential` (task 2.1).
  **`require_reason = true` TURNED OUT TO HAVE A PRICE, MEASURED HERE.** `devenv`
  forwards NO reason flag — there is no `--reason` on the devenv CLI — so with a
  manifest in the tree EVERY `devenv machines …` invocation fails with
  `Accessing secrets requires a reason` until `SECRETSPEC_REASON` is in the
  environment. The scripts export it (`tailnet-preflight.sh`, `bb-pane-run.sh`);
  an interactive `devenv machines info` typed by hand does not get it for free.
  Kept `true` deliberately rather than flipped to save typing: it was a deliberate
  choice in `~/projects/nixos` for reliable attribution, and dropping an audit
  control is not something to do silently while adding a credential. The toggle is
  one line if the friction proves worse than the audit value.
  **Verify** — this is preflight gate 4, using the BUNDLED resolver rather than
  the ambient one:
  ```
  SECRETSPEC_REASON="verifying the manifest" \
    "$(readlink -f .devenv-toolchain)/bin/secretspec" check --no-prompt --json
  ```
  Measured 2026-09-27: `command -v secretspec` is `~/.cargo/bin/secretspec`
  **0.20.0** while devenv 2.4.0 bundles **0.21.0**. The ambient binary tests a
  resolver that will not be the one running `install.secrets`.
- [x] 3.2 Add a `secretspec` block to `devenv.yaml` (`enable: true`,
  `provider: dev`, `profile: default`) by hand.
  **Done 2026-09-27.** `provider`/`profile` are ALIASES matching the
  `[providers.*]`/`[profiles.*]` names in `secretspec.toml`, not URIs; rename one
  without the other and every `machines` command fails. The block is what enables
  **local** execution, which streams the value to the target over authenticated
  SSH. Target execution would instead require the 1Password provider to be
  reachable from the temporary kexec'd installer — a service-account token on a
  throwaway host, for no benefit here.
  The file's header comment was rewritten in the same edit, because it asserted
  the opposite ("NO SECRETSPEC BLOCK, AND NO secretspec.toml IN THIS TREE"). A
  comment that contradicts its file is worse than no comment.
  **Verify:** `git diff devenv.yaml` shows the added block, the rewritten header,
  and no removed input.
- [x] 3.3 Add the `install.secrets` mapping to `machines.netcup` in `devenv.nix`.
  **Done 2026-09-27:** keyed by the absolute path string
  `/var/lib/tailscale/authkey`, with `secret = "TS_AUTH_KEY"`, `owner = "0:0"`,
  `mode = "0600"`. The owner is numeric because the installer cannot look up users
  in the system it is installing into.
  **Verify** — preflight gate 4c, which exists precisely because this file and
  `hosts/netcup/tailnet.nix` cannot see each other:
  ```
  SECRETSPEC_REASON=x ./bin/devenv eval machines.netcup.install.secrets --no-tui
  → {"/var/lib/tailscale/authkey": {"owner":"0:0","mode":"0600","secret":"TS_AUTH_KEY"}}
  ```
- [x] 3.4 Add `hosts/netcup/tailnet.nix` and import it from
  `hosts/netcup/default.nix`.
  **Done 2026-09-27:** `services.tailscale.enable = true`,
  `authKeyFile = "/var/lib/tailscale/authkey"` as a STRING so no value enters the
  store, `extraUpFlags = [ "--hostname=nc" ]`, and `openFirewall` left at its
  default `false` so this change adds no port.
  **Verify:** preflight gate 7, which follows `ExecStart` to the generated script
  and confirms it reads the declared path and pins `--hostname=nc`, while
  `etc/hostname` stays `netcup`.
  **MEASURED WHILE WRITING THIS — THE GATE FAILED ON A CORRECT CONFIGURATION.**
  It grepped the unit file for the key path, but `systemd.services.<name>.script`
  is built into its OWN store path and the unit carries only
  `ExecStart=…/unit-script-tailscaled-autoconnect-start/bin/tailscaled-autoconnect-start`.
  The gate now follows `ExecStart` to the script that actually runs. The
  configuration was never wrong, and it was not changed — worth remembering before
  "fixing" a module to satisfy a grep.

## 4. Evaluation gates (no host contact)

- [ ] 4.1 The whole system still evaluates:
  `./bin/devenv eval machines.netcup.build.nixos`
  Expected: a single store path whose name begins `nixos-system-netcup-`.
- [ ] 4.2 The tailnet settings reached the built system. `machines.netcup.build.nixos`
  evaluates to a store path string, so the read-back surface is the system's own
  `/etc`, not an eval attr path:
  ```
  SYS=$(./bin/devenv eval machines.netcup.build.nixos | python3 -c 'import json,sys;print(json.load(sys.stdin)["machines.netcup.build.nixos"])')
  ls "$SYS/etc/systemd/system/tailscaled.service"
  cat "$SYS/etc/systemd/system/tailscaled-autoconnect.service"
  cat "$SYS/etc/hostname"
  ```
  Expected: both units resolve; the autoconnect unit's script contains
  `cat /var/lib/tailscale/authkey` as a plain path string and `--hostname=nc` in
  its `tailscale up` line; `etc/hostname` is still `netcup`.
- [ ] 4.3 No key material is in the system image, and the declared path is a
  string rather than a store path:
  ```
  SYS=$(./bin/devenv eval machines.netcup.build.nixos | python3 -c 'import json,sys;print(json.load(sys.stdin)["machines.netcup.build.nixos"])')
  "$(readlink -f .devenv-toolchain)/bin/secretspec" run --reason "proving no auth key is in the store" -- \
    sh -c 'test -n "$TS_AUTH_KEY" && printf %s "$TS_AUTH_KEY" | grep -rlF -f - "$1"' _ "$SYS"; echo "exit=$?"
  ./bin/devenv eval machines.netcup.install.secrets
  ```
  Expected: the sweep exits 1 (no match), and the install secrets mapping is
  keyed by the literal string `/var/lib/tailscale/authkey` with
  `secret = "TS_AUTH_KEY"` and `mode = "0600"`. The pattern goes in on **stdin**
  so it never reaches `argv`, where `ps` would show it. A full closure sweep
  (`nix-store -qR "$SYS"`) is the exhaustive form if the narrower one is not
  convincing.
- [ ] 4.4 The enrollment unit is generated and wired to be wanted at boot:
  ```
  grep -E "WantedBy|After|Wants|Type" "$SYS/etc/systemd/system/tailscaled-autoconnect.service"
  ls "$SYS/etc/systemd/system/multi-user.target.wants/tailscaled-autoconnect.service"
  ```
  Expected: `WantedBy=multi-user.target` (or the want-symlink), `After=tailscaled.service`,
  and `Type=notify`.
- [ ] 4.5 The firewall facts are unchanged by this change:
  ```
  ./bin/devenv eval machines.netcup.deploy.facts
  ```
  Expected: firewall enabled, `allowedTCPPorts = [ 22 ]`, no port ranges, and no
  added UDP port. Measured 2026-09-27 on the unchanged tree: enabled true,
  tcp `[22]`, ranges `[]`, ssh ports `[22]`, `rootLogin prohibit-password`. The
  tailscale module only adds a port when `openFirewall` is set, and this change
  leaves it at its default `false`.
- [ ] 4.6 The vault is genuinely a new prerequisite, so the
  *netcup-machine* delta is true rather than asserted:
  ```
  env -u OP_SERVICE_ACCOUNT_TOKEN ./bin/devenv machines info
  ```
  Expected: it fails with a SecretSpec resolution failure naming `TS_AUTH_KEY`.
  Record the exact message in the change before proceeding.
- [ ] 4.7 The build gate before any host contact:
  `./bin/devenv build machines.netcup`
  Expected: exit zero, everything substituted rather than compiled.
- [x] 4.8 The whole gate set in one run, which is the form to actually use — and
  the first task that runs in a pane:
  ```
  ./scripts/bb-pane-run.sh --title "tailnet preflight" -- ./scripts/tailnet-preflight.sh
  ```
  **PASSED 2026-09-27 — `ALL GATES GREEN`, `exit 0 after 7s`.** All nine gates:
  1, 2, 3, 4, 4b, 4c, 5, 6, 7, 8. This subsumes 4.1–4.7 plus the vault and
  name-space gates from groups 1–2.
  **Two things the run itself taught, both fixed:**
  - **devenv's TUI made the pane unreadable.** stdout is a TTY in a pane, so
    devenv rendered a progress TUI that rewrote the screen continuously: the first
    run emitted **664,766 characters** of which almost all were spinner frames,
    burying the gate lines. Every devenv invocation in the script now passes
    `--no-tui`, and the same run came to **4,469 characters** — a 149× reduction,
    with every gate legible. This only bites in a pane; a non-TTY tool call prints
    terse lines anyway, which is why it took running it where the operator watches
    to find. The `--no-tui` flag is accepted both before and after the subcommand
    (both forms tested).
  - **Gate 7 failed on a correct configuration** — see 3.4. The gate now follows
    `ExecStart`.

## 5. Prove the deploy path first (host contact)

- [x] 5.1 Deploy the **current, unchanged** configuration — commit nothing new
  yet, or stash tasks 3.x — so that a failure is attributable to the deploy path
  and not to tailscale:
  ```
  ./scripts/bb-pane-run.sh --title "no-op deploy (prove the path)" -- ./bin/devenv machines deploy netcup
  ```
  Expected: the plan is displayed, activation succeeds, and
  `./bin/devenv machines status netcup` no longer reports
  `phase: "uninitialized"`. Watch the pane rather than only reading the exit
  code: an activation that succeeds after retrying something is worth seeing.
- [x] 5.2 Confirm the host is unharmed by that deploy — SSH as operator and as
  root, and check for units the deploy introduced:
  ```
  ./scripts/bb-pane-run.sh --title "post-deploy host check" -- \
    ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519-op-dev" \
        hbohlen@152.53.92.126 'hostname; systemctl is-system-running; systemctl --failed --no-legend'
  ```
  Expected: login succeeds and `is-system-running` reports `running` or
  `degraded`.
  **If 5.1 fails, stop** — the rest of this change is delivered by the mechanism
  that just failed.

## 6. Deploy the tailnet change (host contact)

- [x] 6.1 Restore the tasks 3.x changes and deploy them, in a pane:
  ```
  ./scripts/bb-pane-run.sh --title "deploy tailnet change" -- ./bin/devenv machines deploy netcup
  ```
  Expected: activation succeeds; `tailscaled.service` is active; the host is
  **not** enrolled yet.
- [x] 6.2 Confirm the pre-enrollment state is the safe one:
  ```
  ./scripts/bb-pane-run.sh --title "tailnet: pre-enrollment state" -- ./scripts/tailnet-verify.sh
  ```
  Expected: the script detects `BackendState` is not `Running`, takes its
  pre-enrollment branch, and reports `PRE-ENROLLMENT CHECKS PASSED`.
  The state to expect, and to understand before calling it a failure:
  `tailscale status` says `Logged out`, `/var/lib/tailscale/authkey` is absent,
  and `tailscaled-autoconnect` is **failed** — it is `WantedBy=multi-user.target`,
  so it starts, loops, hits `cat: /var/lib/tailscale/authkey: No such file or
  directory`, and times out after systemd's default 90 s. Public SSH is
  unaffected throughout; that failure is the expected intermediate state, not a
  broken deploy. The script checks the unit's journal mentions the absent key
  path, because a failure for any *other* reason means the deploy built
  something the configuration does not declare.

## 7. Enroll the live host (host contact)

- [x] 7.1 The enrollment is one visible command. It is its own script because it
  is the step with no rollback, it moves a credential, and as prose it was two
  shell invocations plus a process substitution — the shape that gets mistyped:
  ```
  ./scripts/bb-pane-run.sh --title "enroll nc" -- ./scripts/tailnet-enroll.sh
  ```
  What the script does, all of it visible in the pane: confirms the target and
  that the host is not already enrolled; resolves `TS_AUTH_KEY` through devenv's
  bundled resolver (not the ambient 0.20.0); streams the value into
  `/var/lib/tailscale/authkey` over the ssh channel on **stdin** — never argv,
  never a local file; applies `chmod 0600` and `chown 0:0`; restarts
  `tailscaled-autoconnect` and waits for `BackendState=Running`; prints the
  unit's `Result` and this boot's journal; and fails outright if a key-shaped
  string reached the journal.
  Expected: `ENROLLED`, `Result=success`, and the journal showing
  `Server needs authentication, sending auth key` followed by the state reaching
  `Running`. The key itself is never printed.
- [x] 7.2 Decide the key's life at rest — design open question 2 — and record the
  choice in `docs/tailnet-netcup.md`. The default leaves the file in place, which
  is what keeps a future re-image self-enrolling; `--remove-key` takes it off the
  host, at the cost that a host whose node key is invalidated can then only
  re-enroll during an install.

## 8. Verify reachability (host contact, read-only)

- [x] 8.1 The whole evidence set in one run:
  ```
  ./scripts/bb-pane-run.sh --title "tailnet: enrolled state" -- ./scripts/tailnet-verify.sh
  ```
  Expected: the script detects `BackendState=Running`, takes its enrolled branch,
  and reports `ALL TAILNET CHECKS PASSED`. It asserts, in the requirement's own
  terms: exactly one node named `nc`, `DNSName` `nc.worm-hue.ts.net.`, `Online`
  true, `Tags` containing `tag:server`, the host's own `tailscale ip -4` present
  in its peer record, `tailscale ping nc` answering, MagicDNS resolving to a
  `100.` address, key login over the overlay as both operator and root, the key
  file's mode and owner, and the public path still answering.
- [x] 8.2 The node is new, not the deleted one. Compare against the group 1
  evidence: the `Created` timestamp must be after 2026-09-27T13:10Z, and the node
  ID must differ from `nwjHjrxuF521CNTRL`. A re-listed old node would satisfy
  8.1's name and tag checks and fail this one.
- [x] 8.3 The overlay survives a reboot without re-sending the key. This one
  **reboots a live host**, so run it in a pane and watch it come back:
  ```
  ./scripts/bb-pane-run.sh --title "tailnet: reboot rejoin" -- ./scripts/tailnet-reboot-check.sh
  ```
  Expected: `UNATTENDED TAILNET REJOIN CHECK PASSED` — the host comes back on the
  overlay, `BackendState` is `Running`, the autoconnect unit's `Result` is
  `success`, this boot's journal contains **no** `sending auth key`, and the
  tailnet address is unchanged. The public path is still available, so a host
  that fails to re-enroll is recoverable without the console. The script prints
  how long each path took to come back.
  This is the check that decides whether the change bought what it claims: if
  the key is needed on every boot, the install-time delivery argument collapses.

## 9. Reconcile documentation (no host contact)

- [x] 9.1 Write `docs/tailnet-netcup.md` recording the tailnet name
  `hbohlen.github`, MagicDNS suffix `worm-hue.ts.net`, node name `nc`, tag
  `tag:server`, the declared key path, the auth key's shape and expiry decision,
  and the enrollment procedure from tasks 7.1–7.2 as the procedure of record for
  a live host. Record the four tailnet scripts as the verification method, next
  to the three install scripts they sit beside, and note that
  `scripts/bb-pane-run.sh` is how they are meant to be invoked.
- [x] 9.2 Update `docs/handoff-followups.md`: follow-up 2's tailnet half is
  settled by this change, and the remaining half (tailnet-only access) is what
  follow-up 1 now depends on. The stale-`nc` note in the archived change's
  proposal is historical and stays as it is.
- [x] 9.3 Record the measured facts this change learned that the next reader
  will need. Each of these cost a real failure and none is guessable:
  - **The Machine's effective nixpkgs** is `cachix/devenv-nixpkgs@c2f38fe7…`
    → `NixOS/nixpkgs@c7def046…`, with patches that do not touch tailscale or
    systemd (they are poetry, lean4 and llvm-darwin).
  - **Local install payloads require pre-pinned host keys** — for the original OS
    *and* the kexec installer when they differ.
  - **`devenv machines info` output is ANSI-wrapped** and `NO_COLOR` does not
    suppress it, so anything matching on it must strip escapes first.
  - **The ambient `secretspec` is a different version from devenv's bundled one**
    (0.20.0 vs 0.21.0). Use the bundled resolver by path.
  - **`require_reason = true` costs every `devenv machines …` command an
    environment variable.** devenv forwards no reason flag, so `SECRETSPEC_REASON`
    must be set or the command dies with "Accessing secrets requires a reason".
    Scripts export it; hand-typed commands do not get it for free.
  - **devenv renders a progress TUI whenever stdout is a TTY**, which floods a bb
    pane (measured: 664,766 characters for one build, almost all spinner frames).
    Pass `--no-tui` in a pane. The same command is terse under a non-TTY tool call,
    so this is invisible until it is run where someone is watching.
  - **A systemd unit's script body is not in the unit file.**
    `systemd.services.<name>.script` builds to its own store path and the unit
    holds only `ExecStart=…/unit-script-<name>-start/bin/<name>-start`. Grepping
    the unit for a string from the script fails on a correct configuration.
  - **A bb terminal pane inherits neither `OP_SERVICE_ACCOUNT_TOKEN` nor
    `BB_THREAD_ID`**, and a session closes the instant its command exits — the
    generic technique is in the `bb-terminal-pane` skill.
  - **The `dev` vault's service account is read-only, and secretspec resolves an
    item's field by the label the item actually has.** The auth key is an
    `API_CREDENTIAL` whose concealed field is `credential`, not `password`; an
    `op item get --format json` shows the ids and types (never run it bare — it
    prints the value).

## 10. Validation and promotion

- [x] 10.1 `openspec validate add-netcup-tailnet --strict --json` returns
  `valid: true`, with any `issues` read individually — an INFO-level note is a
  style signal, not a failure.
- [x] 10.2 `openspec status --change add-netcup-tailnet` shows every artifact
  complete.
- [x] 10.3 Every requirement in `specs/netcup-tailnet/spec.md` and the modified
  requirement in `specs/netcup-machine/spec.md` has been exercised by the task
  that names it, or is recorded in the change as unverified with the reason.
  **The `install.secrets` half of the enrollment mechanism cannot be verified
  before the next re-image; if no re-image happens in this change, say so here
  explicitly rather than marking it done.**
  **No re-image happened in this change, so that half is UNVERIFIED — stated
  explicitly, as this task requires.** What the live host proved is the *reading*
  end of the mechanism (the declared path, the generated unit, and the enrollment
  that unit performs), exercised through `tailnet-enroll.sh`. What remains
  unproven is the *delivery* end: `install.secrets` writing
  `/var/lib/tailscale/authkey` between `nixos-install` and the first reboot.
  `docs/tailnet-netcup.md` §6 carries the same statement for a reader. Also
  unverified and not verifiable from here: the auth key's expiry and
  reusable-vs-single-use shape (design open question 1) — console-side properties
  that neither the vault item nor the host carries.
- [x] 10.4 Archive deliberately, after 10.1–10.3:
  `openspec archive add-netcup-tailnet` — it promotes the delta specs into
  `openspec/specs/` and skips validation with `--yes`, so validation must have
  already run.
  **Done 2026-09-27** with `openspec archive add-netcup-tailnet --yes`, after
  10.1 returned `valid: true` / `issues: []` and 10.2 showed 4/4 artifacts
  complete. It promoted `netcup-tailnet` and `netcup-operations` into
  `openspec/specs/` as new capabilities and updated `netcup-machine` in place,
  and moved this change to `openspec/changes/archive/2026-09-27-add-netcup-tailnet/`.

---

## Execution notes — 2026-09-27

What actually happened when this change was run, including two script defects and
one design correction. The reader-facing form of all of it is
`docs/tailnet-netcup.md` §5.

Group 4's 4.1–4.7 stay unticked on purpose: 4.8's note says it subsumes them, and
the whole set ran green in one command (repeatedly, including with the new
`ConditionPathExists` gate from D10).

**Host contact, in order, every step through `scripts/bb-pane-run.sh`:**

- **5.1** no-op deploy of the stashed 3.x tree — the deploy path's first run
  against this host: `netcup: deployed`, exit 0.
  `machines status netcup` went from `phase: "uninitialized"` to
  `outcome: "succeeded"`.
- **5.2** post-deploy host check — `running`, no failed units.
- **6.1** deploy the tailnet change — **FAILED, rolled back**:
  `switch-to-configuration` exit 4, `phase: "rolled-back"`, previousSystem
  restored. Cause from the host's journal: the absent-key unit *failed*. Fixed by
  D10, then redeployed: `netcup: deployed`, exit 0, 19.3 s activation.
- **6.2** `tailnet-verify.sh` — `PRE-ENROLLMENT CHECKS PASSED`: tailscaled
  1.102.4 active, `NeedsLogin`, key absent, unit *skipped* (`ConditionResult=no`).
- **7.1** `tailnet-enroll.sh` — `ENROLLED`, `Running after 2s`, node
  `100.95.168.15 nc nc.worm-hue.ts.net`, no key-shaped string in the journal.
- **7.2** recorded in `docs/tailnet-netcup.md` §3: the key is **left at rest**
  (the script's default), `0600 root:root`; expiry and shape flagged as
  unrecorded rather than guessed.
- **8.1** `tailnet-verify.sh` — `ALL TAILNET CHECKS PASSED`.
- **8.2** node freshness — one node named `nc`, `Created` 2026-09-27T17:22:36Z,
  deleted id `nwjHjrxuF521CNTRL` absent, `tag:server`, `Online`.
- **8.3** `tailnet-reboot-check.sh` — failed twice for *script* reasons, then
  passed: `UNATTENDED TAILNET REJOIN CHECK PASSED`, public path back in 22 s,
  overlay in 25 s, `BackendState` Running, no `sending auth key`, address
  unchanged at `100.95.168.15`.

**The three findings, by cost:**

1. **A failed systemd unit aborts a deploy, so the pre-enrollment state was
   unreachable** → design D10 (`ConditionPathExists` on the generated unit), a
   new preflight gate grepping the *built* unit for it, the pre-enrollment
   evidence changing from a journal line to `ConditionResult=no`, and a new
   scenario in `specs/netcup-tailnet/spec.md`.
2. **`scripts/tailnet-reboot-check.sh` could never pass — two independent
   defects.** `timeout 15 rsh …` cannot run a shell *function* (rc=127, stderr
   discarded, therefore read as "host not back yet"), so it reported a false
   negative on a host that was down for **ten seconds**; and it ran `python3`
   *on the host*, which has none, so `BackendState` was unreadable on a host that
   was demonstrably Running. Both fixed, and rc=127 now fails loudly so a broken
   probe can never look like an unreachable host again.
3. **`scripts/bb-pane-run.sh` silently ran nothing for multi-word commands and
   reported exit 0** — see task 0.3's caveat; fixed, with a guard.

**Two operator-visible flags the docs now name:** `devenv machines deploy` stops
at `Apply this fleet plan? [y/N]` — pass `--yes` in a pane — and it renders a
progress TUI on a TTY, so pass `--no-tui`.

**One gate is now permanently red, on purpose: `tailnet-preflight.sh` step 5.**
It asserts that the name `nc` is free, which is a *pre*-enrollment precondition —
and the enrolled host *is* that node, so from now on the preflight exits 1 there
(`COLLISION: nc.worm-hue.ts.net. online=True tags=['tag:server']`). Its job is the
fresh-enrollment case: a re-image or a second host, where an old registration
would push the new node to `nc-1`. The message now names both cases and points at
`scripts/tailnet-verify.sh` for a live host, and `docs/tailnet-netcup.md` §4 says
it outright — a gate everyone learns to ignore is worse than no gate.

**10.4 was done after all** — `openspec archive add-netcup-tailnet --yes` — but it
took two attempts, and the first is the interesting one. The archive **aborted**:

```
netcup-machine MODIFIED failed for header "### Requirement: The Machine evaluates
to a bootable NixOS system" - current spec contains scenario(s) not present in the
modified block: "Evaluation requires no secret provider"
Aborted. No files were changed.
```

The delta had rewritten that requirement for the vault-on-the-path world and
dropped a scenario whose *precondition* this change removes (a repository with no
`secretspec.toml`). openspec refuses an implicit drop, matching scenario **by
name**, so the scenario is now carried in the block with the inversion stated and
marked RETIRED in `openspec/specs/netcup-machine/spec.md`. `--yes` skips
*confirmation*, not that check — so 10.4 could not have been forced through, and
the abort was a genuine "you are about to delete a claim" warning. Result:
`netcup-machine` 1 modified, `netcup-operations` 3 added, `netcup-tailnet` 5
added (`+8, ~1, -0`); `openspec validate --all --strict` → 5/5 specs valid.

**The archive also flagged 7 incomplete tasks (group 4's 4.1–4.7), which is
expected**: 4.8's note says it subsumes them, and the whole set ran green in one
command. They stay unticked because ticking them individually would claim seven
separate runs that never happened — the one command is the evidence, and 4.8 is
where it is recorded.
