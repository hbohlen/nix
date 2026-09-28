## 1. Declare the host-side preconditions (repository only, no host contact)

- [x] 1.1 Add a module that declares the host's nix settings to this repository:
      `nix.settings.experimental-features = [ "nix-command" "flakes" ]`. Leave
      `trusted-users` as `root` (design D5) rather than adding the operator.
      — Verify: `bin/devenv eval machines.netcup.build.nixos` still returns a
      `nixos-system-netcup-*` path, and the built system's `etc/nix/nix.conf`
      contains both features.
- [x] 1.2 Generate the loopback keypair in a scratch directory outside the
      repository, then declare its public half in the same place root's operator
      key is declared (design D4), leaving the operator key in place. The
      private half stays in the scratch directory until 3.3 installs it on the
      host at the declared `sshOpts` path; it never enters the repository.
      — Verify: `bin/devenv eval machines.netcup.deploy.facts` reports two keys
      for `root`, and `git grep` for the private half finds nothing.
- [x] 1.3 Add `git` to the host's package set; it is measured absent today and
      the clone step needs it.
      — Verify: `bin/devenv eval machines.netcup.build.nixos` succeeds and the
      evaluated `environment.systemPackages` contains `git`.
      **Extended after the first bootstrap, by measurement rather than plan
      (design R10): the package set also carries `pkgs._1password-cli`, because
      SecretSpec's 1Password provider is a wrapper around the `op` BINARY and
      resolves nothing without it — proven by putting a sentinel `op` on `PATH`
      and watching `machines info` invoke it as `vault list --format json`. The
      attribute is `_1password-cli`: `onepassword` (the name secretspec's own
      install hint prints) is missing from the pinned nixpkgs and `_1password` is
      a `throw`. The package is unfree, so `allow_unfree: true` is declared in
      `devenv.yaml`.**
      — Verify: the built system's path contains `bin/op` and it reports
      `2.39.0`, the same version the workstation runs (measured:
      `/nix/store/wrxgslw9…-system-path/bin/op -> 2.39.0`).
- [x] 1.4 Document in `devenv.nix`'s `sshOpts` comment that the `-i` path is
      machine-local — the vault key on a workstation, the loopback key on the
      host (design D4) — so the one declaration is right on both sides. The
      earlier draft's per-invocation `-O` override is not available: `bin/devenv
      machines deploy --help` reports supported types `string, int, float, bool,
      path, pkg, pkgs`, none of which replaces a string list, and
      `IdentitiesOnly=yes` makes any other key path invisible to the
      declaration.
      — Verify: `bin/devenv machines info` still lists exactly one machine whose
      declared target is the public address, and the `sshOpts` declaration
      itself is unchanged.
- [x] 1.5 Run the full eval gate on the workstation, with no host contact:
      `bin/devenv machines info`; `bin/devenv machines check netcup`;
      `bin/devenv eval machines.netcup.build.nixos`.
      — Verify: all three exit 0. `check` still reports
      `access-analysis-incomplete` (risk R8, pre-existing, not a failure).

## 2. Settle the vault question before anything runs on the host (no host contact)

- [x] 2.1 Measure the wholesale provider override (design D3's rejected
      alternative, open until measured here) in a scratch copy outside the repository: run
      `machines info` with `SECRETSPEC_PROVIDER` pointed at a value-bearing
      provider and the 1Password token unset, and check whether
      `install.secrets` still resolves `TS_AUTH_KEY`.
      — Verify: the command's exit code and the error text, recorded verbatim;
      a scratch directory under `/tmp`, never the repository.
- [x] 2.2 Decide between the credential-at-rest route and the provider route
      against 2.1's result, and write the decision into `design.md`'s D3 and the
      open questions, replacing the one that is not chosen.
      — Verify: `design.md` names one route as chosen and states what the other
      cost; no artifact still lists it as undecided.
- [x] 2.3 Record which remote and which branch or bookmark the host will clone
      (open question 1). This is an operator decision with no evidence in the
      tree; ask rather than infer.
      — Verify: the answer appears in the procedure document written in 8.1.
      **Done: public GitHub repository `hbohlen/nix`, branch `main` — the same
      answer 5.1 executed and the fresh clone in 5.1's evidence read back. It is
      now written in `docs/self-deploy-netcup.md` §1, and §1 records what the
      tree could not decide: the repository is public so the CLONE needs no
      credential, and the host has NO push credential at all, so edits are
      authored and pushed on the workstation and the host only pulls.**

## 3. Bootstrap the host from the workstation (first write to the host)

- [x] 3.1 Deploy this change from the workstation — the only ordering that
      works, because the host cannot run `devenv` until 1.1 lands (design D7).
      Run it in an operator-visible pane per `netcup-operations`.
      — Verify: the pane's session identifier is reported, and
      `bin/devenv machines status netcup` shows the operation succeeded rather
      than rolled back.
- [x] 3.2 Confirm the change did not weaken the public path.
      — Verify: the operator key still logs in over the public address, and
      `bin/devenv eval machines.netcup.deploy.facts` still reports the firewall
      enabled with port 22 as the only allowed TCP port and no port ranges.
- [x] 3.3 Install the loopback key's private half on the host at the path 1.4
      documented (`/home/hbohlen/.ssh/id_ed25519-op-dev`), root-owned `0600`,
      then delete the scratch copy from the workstation.
      — Verify: the file's mode and owner are read back over the existing SSH
      session and are `0600`/`root`; the scratch directory is gone; no command
      printed the private half.

## 4. Isolated host probes, no devenv involved (read-only)

Each probe settles one precondition independently, so a later failure can be
attributed rather than guessed at.

- [x] 4.1 Confirm the nix features are available non-interactively, with no
      `NIX_CONFIG` in the environment.
      — Verify: `nix flake --help` (or any `nix-command` subcommand) runs on the
      host as a non-interactive process, from `ssh root@152.53.92.126 '…'`.
- [x] 4.2 Confirm the loopback identity works with no agent and no prompt.
      — Verify: `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i
      /home/hbohlen/.ssh/id_ed25519-op-dev root@localhost id -u` prints `0`.
- [x] 4.3 Confirm the loopback target is a usable store.
      — Verify: with `NIX_SSHOPTS` naming the declared identity (R9),
      `nix store info --store ssh://root@localhost` reports a store with a
      trusted connection rather than failing to start the SSH connection.
      Measured 2026-09-27: with the declared key in place but no `NIX_SSHOPTS`,
      it fails with `root@localhost: Permission denied (publickey)`, so the
      variable is part of this gate and not an extra — see design R9.
- [x] 4.4 **Settle R1: the copy-to-self step.** Run the transfer in isolation
      against a path already present, before any deploy depends on it.
      — Verify: with `NIX_SSHOPTS` naming the declared identity,
      `nix copy --to ssh://root@localhost /nix/store/$(readlink -f
      /run/current-system)` exits 0 and transfers nothing.
      **Settled 2026-09-27: it printed `copying 0 paths...` and exited 0, so the
      copy-to-self is a no-op and D1's chosen route stands.** Without
      `NIX_SSHOPTS` it fails to start the SSH connection (R9).

## 5. The checkout and the pinned toolchain on the host

- [x] 5.1 Create the remote and publish: a branch or jj bookmark at the current
      revision, pushed per 2.3's answer. The repository is jj-colocated in
      detached HEAD with no bookmarks today, so there is nothing to push yet.
      — Verify: `git remote -v` shows the remote; the branch or bookmark resolves
      to the same commit as the working copy's tip.
      **Done 2026-09-27: public GitHub repository `hbohlen/nix`, with the jj
      bookmark `main` pushed and set as the default branch. Verified from a
      fresh clone of the remote: `main` resolves to the same commit as the
      working copy's tip, 48 tracked files, no file tracked against `.gitignore`,
      and no credential in the tree or anywhere in the history. One file had been
      tracked against `.gitignore:15` and is now untracked —
      `.machines/netcup/facter.json`, the generated hardware report; it remains in
      the ancestry at 868f8c9 (design OQ1).**
- [x] 5.2 Clone to `/home/hbohlen/nix` on the host. `git` only — jj is not needed
      to build or deploy.
      — Verify: the host's `git rev-parse HEAD` equals the pushed revision.
- [x] 5.3 Obtain the pinned toolchain from `devenv.cachix.org` and root it in the
      checkout, using `bin/devenv`'s documented command. It is measured present
      in that cache, so this is a download and not a Rust build.
      — Verify: `bin/devenv --version` on the host reports 2.4.0 or newer, and
      the substituted path is the same store path the workstation uses.
- [x] 5.4 Build the system on the host with the workstation unreachable.
      — Verify: `bin/devenv build machines.netcup` on the host prints a
      `nixos-system-netcup-*` path with the same name the workstation produces,
      and no remote builder participated.
      **Done 2026-09-27. ORDER CORRECTED BY MEASUREMENT: this task cannot run
      before 6.1. `devenv build` evaluates the Machine, a Machine resolves its
      whole SecretSpec profile on every invocation, and the host without the
      credential fails with `No accounts configured for use with 1Password CLI`
      (exit 1, pane term_guqnzvkumu). With 6.1 in place it also needs R11 — the
      store is read-only at boot, and `devenv` links libnix in-process and aborts
      with `Failed to open Nix store` until it is remounted rw. Both fixed, the
      clean run reports `store options: rw`, `remount unit: active`, exit 0.**
      — Verify: with the unit active, `bin/devenv build machines.netcup` on the
      host exits 0 and names the same `nixos-system-netcup-*` path the
      workstation produces for the same revision, with no remote builder.

## 6. The SecretSpec profile on the host

- [x] 6.1 Establish the route chosen in 2.2: either the credential at rest
      (root-only `0600`, read-only scope) or the provider override.
      — Verify: the file's mode and owner are read back, and nothing prints the
      credential's value.
      **Done 2026-09-27 at `/root/.config/op-sa-token`: `600 root:root`, 857
      bytes, sha256 prefixes read back equal on both sides (`8ac84b12233484a7`)
      without printing the value — the same path shape as the workstation's
      `~/.config/op-sa-token`, so the one convention holds on both machines.**
      — Verify: `stat -c '%a %U:%G' /root/.config/op-sa-token` is `600 root:root`,
      and no command in the pane printed the value.
- [x] 6.2 Confirm a non-interactive `machines` invocation resolves the profile on
      the host.
      — Verify: `bin/devenv machines info` at `/home/hbohlen/nix` on the host
      exits 0 unattended, listing the netcup machine.
- [x] 6.3 Confirm install-time delivery was not traded away and no new secret
      value was written.
      — Verify: `secretspec.toml` still declares `TS_AUTH_KEY` and the Machine's
      `install.secrets` entry is unchanged; a sweep of the paths this change
      added finds no secret value.

## 7. The self-deploy loop

- [x] 7.1 Run the read-only machine operations against the loopback target.
      — Verify: `bin/devenv machines check netcup -O
      machines.netcup.target.host:string root@localhost` and `machines status`
      with the same override both exit 0 and report the host's facts.
- [x] 7.2 Run the **no-op** self-deploy: the host currently matches its
      declaration (`Closure: +0 / -0`), so nothing new is started. This is the
      end-to-end proof and risk R2's first exercise.
      — Verify: `bin/devenv machines deploy netcup -O
      machines.netcup.target.host:string root@localhost --yes` completes, and
      `machines status netcup` reports succeeded, not rolled back.
      **Done 2026-09-27 on the host over `root@localhost` (pane
      term_gmr9rc85zk), after the checkout was brought to the pushed tip
      `6ab24452` with 0 dirty paths. The host's own deploy reported
      `Closure: +0 / -0`, `copying 0 paths...`, `netcup: deployed`, exit 0 in
      5.16 s, and `machines status` then reported `phase: succeeded` with
      `previousSystem == requestedSystem` — not rolled back, so R2's control
      channel survived activation. `NIX_SSHOPTS` naming the declared loopback
      identity was required throughout (R9), and the store had to be `rw` via
      R11's unit. The running system is `zzh5rm53kfgwyg9x5r6fc0db22zbz6y2`, the
      same path the host built itself and the workstation built for the same
      revision.**
- [x] 7.3 Confirm the running system is the one built on the host.
      — Verify: `readlink -f /run/current-system` on the host equals the store
      path 5.4's build produced.
- [x] 7.4 Deploy a real change from the host and observe it applied.
      — Verify: the changed fact is read back on the running host, and
      `machines status` reports succeeded.
      **Done 2026-09-28 (pane term_qdufydm47i). The real change is the loop
      record `hosts/netcup/self-deploy.nix` now declares:
      `/etc/netcup-self-deploy/loop.json`, a world-readable file naming the
      repository, the branch, the checkout, the loopback override and the
      identity path. Every earlier deploy in this change was a no-op, which
      proved the path but not that the path can CHANGE anything. Run ON the host
      over `root@localhost` by `scripts/self-deploy-host.sh`: the plan reported
      `Closure: +4 / -3 store paths` and `copying 0 paths...` — the host built
      the new system itself rather than receiving it — then `netcup: deployed`,
      `phase: succeeded`, `outcome: succeeded`, previousSystem
      `18ml7pjxf4s6…` / requestedSystem `18ml7pjxf4s6…`, `/run/current-system`
      equal to the requested path, exit 0 in 32 s. The changed fact reads back on
      the RUNNING host: `readlink /etc/netcup-self-deploy/loop.json` is
      `/etc/static/netcup-self-deploy/loop.json`, and the file's contents name
      branch `main` — the branch `scripts/self-deploy-drift.sh` compares.
      `scripts/self-deploy-verify.sh` now reads that record back as part of its
      run (24 checks, ALL CHECKS GREEN).**
- [x] 7.5 Test the rollback deliberately, with the tailnet reachable (risk R3).
      Do not run this until 7.2 and 7.4 pass.
      — Verify: after deploying a configuration whose activation fails, the
      previously running system is restored, the host answers SSH, and
      `machines status` reports the failure and its outcome. Then correct it and
      deploy again successfully, with no re-image.
      **Done 2026-09-28. The tailnet was confirmed reachable FIRST, on both the
      root and the operator path (`ssh root@nc.worm-hue.ts.net hostname` →
      `netcup`), so the probe ran with a second channel open. The probe was an
      uncommitted unit on the host — `ExecStart = coreutils/false`, wanted by
      `multi-user.target` — and the check was run against it before the deploy:
      `scripts/self-deploy-drift.sh` FAILED, naming
      `M hosts/netcup/self-deploy.nix`, which is 8.3's second half. The deploy
      (pane term_zbwtbxfb27) reported `× Fleet deployment stopped. Completed:
      none.` / `netcup: Transaction deployment-vAyIhUZ8cIHwuxr97U4uFOvo was
      rolled back on netcup: Command '[.../switch-to-configuration', 'switch']'
      returned non-zero exit status 4.`, `phase: rolled-back`, `outcome:
      rolled-back`, and `error` carrying the same exit status 4. Afterwards the
      running system was the previous one again (`18ml7pjxf4s6…`),
      `systemctl is-system-running` was `running`, the probe unit was gone
      (`is-failed` inactive), and the host answered SSH on BOTH channels. The
      transaction took 304 s — that is its window, not a hang. The probe was then
      discarded (`git checkout -- .`, 0 dirty paths), the drift check went green
      again (pane term_ppubp58iks), and the same loop deployed successfully with
      `Closure: +0 / -0`, `phase: succeeded`, exit 0 in 30 s, no re-image (pane
      term_djp734mtz2). `scripts/self-deploy-host.sh --probe-uncommitted` is the
      door this test needs, and the only one: it passes `--allow-dirty` to the
      drift check without relaxing the revision check.**

## 8. Procedure and scripts

- [x] 8.1 Write the procedure document for the host-side loop — clone, edit,
      build, deploy, verify — naming each step and the command that verifies it,
      including which remote to use (2.3) and that edits are pushed from the host
      so the checkout cannot drift (risk R5).
      — Verify: every step in the document names a command; a reader can follow
      it without consulting this change.
      **Done: `docs/self-deploy-netcup.md`. One premise of this task was
      MEASURED WRONG AND CORRECTED: edits are not pushed from the host, because
      the host has no push credential — no `/root/.gitconfig`, no
      `/root/.git-credentials`, no credential helper, and
      `git push --dry-run origin main` answers `could not read Username for
      'https://github.com': terminal prompts disabled`. The document says so in
      §1, with the measurement, and R5 is answered by the drift check (8.3)
      instead: the host holds only what was published to it.**
- [x] 8.2 Add verification scripts in the shape `scripts/` already uses, and wrap
      host-touching ones for an operator-visible pane per `netcup-operations`.
      — Verify: each script is runnable and reports its verdict and the pane's
      session identifier; no script prints a secret value.
      **Done: five scripts. `self-deploy-preflight.sh` (workstation, no host
      contact, ten gates, ALL GATES GREEN 2026-09-28), `self-deploy-drift.sh`
      (8.3), `self-deploy-verify.sh` (read-only, host-touching, 24 checks, ALL
      CHECKS GREEN), `self-deploy-run.sh` (the deploy, ON the host) and
      `self-deploy-host.sh` (the pane entry that wraps the run). Each prints its
      own verdict and exits nonzero on failure; the host-touching ones are run
      through `scripts/bb-pane-run.sh`, which reports the pane's session
      identifier (term_3d9pnh8ki2, term_fbycuu4b5b, term_qdufydm47i,
      term_r98aga7nnb, term_wu4nagsfwq, term_3gyvh6usdv, term_jr67cwzr85,
      term_zbwtbxfb27, term_ppubp58iks, term_djp734mtz2). No script prints a
      secret value: the credential is read back by MODE and by a 16-character
      sha256 prefix on both machines, and `self-deploy-run.sh` reads the token
      into a variable with the file named but the value never echoed.**
- [x] 8.3 Add a drift check comparing the host's checkout revision with the
      pushed revision, so a hand-edited host copy is visible rather than silent.
      — Verify: the check passes on a freshly cloned host and fails after a
      deliberate uncommitted edit on it.
      **Done: `scripts/self-deploy-drift.sh`. It compares the host's `HEAD` with
      the REMOTE (`git ls-remote`), reports the uncommitted paths, and prints the
      commit range read from the WORKSTATION's object store — a host that is
      behind has not fetched, so `git log HEAD..origin/main` ON the host prints
      nothing, measured on this check's first real run. Two modes, because
      "behind" and "dirty" are different questions: strict (the state a deploy
      must be read at) and `--fast-forwardable` (the state right after a push,
      where `BEHIND` is a loud note and dirty work still fails). Both directions
      of this task's verify were measured on the live host: it passed at the
      published revision with nothing uncommitted (panes term_3d9pnh8ki2 reports
      the first real drift — the host one commit behind — and term_ppubp58iks the
      clean state after the probe), and it FAILED, naming
      `M hosts/netcup/self-deploy.nix`, when the rollback probe was left
      uncommitted on the host (pane term_jr67cwzr85, task 7.5).**

## 9. Validation and promotion

- [x] 9.1 Re-read every scenario in `specs/netcup-self-deploy/spec.md` against
      the evidence collected above; for each, either name the command output that
      proves it or mark it as not yet provable, with the reason.
      — Verify: no scenario is left uncited and unremarked.
      **Done 2026-09-28, all 34 scenarios, in spec order. Citations name the
      command or pane; "NOT PROVABLE" says why.**
      *R1 — pushable, same history.* A remote and a published revision: `git
      remote -v` → `origin https://github.com/hbohlen/nix.git` (public), `git
      ls-remote origin refs/heads/main` → `ce78f334`. The host is at the pushed
      revision with nothing uncommitted: drift check strict, pane
      term_ppubp58iks, host HEAD `ce78f334` == `origin/main`. A fresh clone
      reproduces the tree: 5.1's recorded fresh clone at the then-current
      revision, NOT re-cloned in this session — the revision it produced is the
      one the host now runs (5.1's own evidence).
      *R2 — the pinned toolchain.* The pinned version answers on the host:
      `readlink .devenv-toolchain` on the host →
      `axhrys71…-devenv-wrapped-2.4.0`, same path as the workstation, and
      `…/bin/devenv --version` → `devenv 2.4.0+b904dcb (x86_64-linux)`. It was
      substituted, not built: same store path on both machines, downloaded from
      `devenv.cachix.org` (5.3). A build without the workstation's store: the
      host built and activated 7.4's change with `copying 0 paths...`, so its own
      store supplied everything — but the workstation was REACHABLE during that
      run, so the scenario's strict form rests on 5.4, not on this session.
      *R3 — nix preconditions.* Flakes and `nix-command` non-interactively:
      `grep ^experimental-features /etc/nix/nix.conf` → `nix-command flakes`
      (verify pane term_3gyvh6usdv), and every host-side `bin/devenv` build and
      deploy in this session ran unattended with no `NIX_CONFIG` set by the
      caller. The deploying identity is trusted or root: the deploy runs as root
      on the host and copies over the loopback identity (7.2/7.4: `Closure: +4 /
      -3`, `copying 0 paths...`, then activation; no signature failure in any
      run). The settings survive a rebuild: the `nix.conf` read above came AFTER
      the 7.4 rebuild that added a store path (`Closure: +4 / -3`), and after the
      7.5 rollback and redeploy, because it is declared, not hand-applied.
      *R4 — the loopback deploy identity.* Login without an agent:
      `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i /home/hbohlen/.ssh/
      id_ed25519-op-dev root@localhost 'id -u'` → `0`. The loopback target is a
      reachable store: `nix store info --store ssh://root@localhost` exits 0 and
      `nix path-info --store ssh://root@localhost $(readlink -f
      /run/current-system)` returns the running system's path. NUANCE RECORDED:
      Nix 2.34.8's `store info` prints ONLY `Store URL: …` — there is no
      trusted-connection line to read, so "trusted" rests on the deploy's own
      successful copy and activation, not on that output. No private key material
      committed or stored: preflight gate 8 (both public halves declared, the
      fingerprint of the loopback public half recomputed, no private half in the
      tree or in the built system).
      *R5 — the SecretSpec profile.* Unattended `machines info` on the host: 6.2,
      and stronger here — every `machines deploy`/`status` in this session ran on
      the host with no prompt (7.2, 7.4, 7.5). Install-time delivery not traded
      away: 6.3's read-back (`secretspec.toml` still declares `TS_AUTH_KEY`, the
      Machine's `install.secrets` unchanged) — recorded, not re-measured here. No
      secret value anywhere it could be read: preflight gate 8, 6.1's mode
      read-back (`600 root:root`), 6.3's sweep, and the verifier's compare of the
      credential's sha256 prefix on both machines without printing the value.
      **THE SCENARIO WAS AMENDED during this pass** — as first written ("no new
      secret value is written anywhere") it is contradicted BY CONSTRUCTION by
      the route 2.2 chose and D3 records, which places the credential at rest on
      the host. See the amendment note in the spec.
      *R6 — one declaration, override per invocation.* Exactly one machine, at
      the public target: preflight gate 2 → `| netcup | x86_64-linux |
      root@152.53.92.126 | nixos |`, and gate 3 reading the declared target. The
      override redirects only the invocation: every host-side command used
      `-O machines.netcup.target.host:string root@localhost`, and `machines info`
      run afterwards still reports `root@152.53.92.126` (preflight gate 3, run in
      the same session, after those deploys).
      *R7 — rebuild and activate.* An unchanged configuration deploys
      successfully: 7.2 (`Closure: +0 / -0`, `phase: succeeded`) and again after
      the rollback (pane term_djp734mtz2, exit 0). The activated system is the
      one built on the host: 7.3, and the run script compares `/run/current-
      system` with the path the host evaluated before deploying — equal in both
      the 7.4 and the 7.5 runs. The host's build matches the workstation's: for
      revision `736c4b7a` the host produced and activated `18ml7pjxf4s6…` and the
      workstation's preflight built the same `18ml7pjxf4s6…`. No remote builder:
      the host's own pane shows the build happening there (`✓ Building in 8.93s`)
      and `copying 0 paths...` — nothing was transferred IN, and
      `--use-machines-as-builders` was never passed.
      *R8 — a failed deploy restores the previous system.* A broken
      configuration rolls back: 7.5, `phase: rolled-back`, `error` carrying
      `switch-to-configuration … exit status 4`, the previous system running
      afterwards, the host answering on both channels. The outcome is readable
      after the fact: the same run read it from the host's own deploy state
      (`machines status … -O … root@localhost`) twice — before and after the
      pull — with no transcript needed. NUANCE RECORDED: that record is the
      target's CURRENT deployment state, so the next successful deploy replaces
      it; the failure is re-readable until then. Recoverable without a re-image:
      7.5's second half — probe discarded, deploy succeeded, exit 0.
      *R9 — the public path is not weakened.* Firewall facts unchanged: preflight
      gate 9 → `enabled: True tcp: [22] ranges: []`, `rootLogin:
      prohibit-password`, `hostname: netcup`, after all of this session's writes.
      The public path still works: the verifier logs in as root AND as the
      operator over `152.53.92.126`, and the loop itself ssh's that address.
      **Root over loopback when a LATER change narrows the permitted addresses:
      NOT PROVABLE by this change, and deliberately so** — it is a constraint
      HANDED FORWARD to the hardening change, because this change does not
      restrict addresses at all. What exists to constrain it: `PermitRootLogin =
      prohibit-password` with both keys declared in `hosts/netcup/default.nix`,
      and risk R7 recorded in the design.
      *R10 — documented, re-readable.* The procedure names its verification:
      `docs/self-deploy-netcup.md` §3-§5, every step carrying its command.
      The loop's record outlives the session: `machines status netcup -O
      machines.netcup.target.host:string root@localhost` on the host prints the
      deployment's id, phase, outcome, previous and requested system, as read
      during the 7.4 and 7.5 runs.
      **One scenario not provable (R9), two resting on this change's earlier
      recorded evidence rather than a fresh measurement (R1's fresh clone, R2's
      workstation-unreachable build, R5's install-time delivery), and one
      scenario amended because the chosen design contradicted it. Nothing is
      left uncited and unremarked.**
- [ ] 9.2 Run `openspec validate add-netcup-self-deploy --strict --json` and read
      the `issues` array rather than asserting it is empty; an INFO note is a
      style signal, an `error` is a failure.
      — Verify: `valid: true` with no `error`-level issue.
      **Done 2026-09-28 after the spec amendment in 9.1:
      `{"id":"add-netcup-self-deploy","type":"change","valid":true,"issues":[]}`
      — `issues` is EMPTY, not merely free of errors: no INFO style note either.
      `summary.totals` `passed: 1, failed: 0`, `root.source: nearest` at
      `/home/hbohlen/nix`.**
- [ ] 9.3 Promote: `openspec archive add-netcup-self-deploy`, then confirm the
      capability lands at `openspec/specs/netcup-self-deploy/`.
      — Verify: `openspec list --specs` contains `netcup-self-deploy` with its
      requirement count, and the change directory is under `archive/`.
