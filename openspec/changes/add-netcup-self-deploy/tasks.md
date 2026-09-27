## 1. Declare the host-side preconditions (repository only, no host contact)

- [ ] 1.1 Add a module that declares the host's nix settings to this repository:
      `nix.settings.experimental-features = [ "nix-command" "flakes" ]`. Leave
      `trusted-users` as `root` (design D5) rather than adding the operator.
      — Verify: `bin/devenv eval machines.netcup.build.nixos` still returns a
      `nixos-system-netcup-*` path, and the built system's `etc/nix/nix.conf`
      contains both features.
- [ ] 1.2 Declare the loopback deploy identity (design D4): the public half of a
      host-local keypair into the same place root's operator key is declared,
      leaving the operator key in place. The private half never enters the
      repository.
      — Verify: `bin/devenv eval machines.netcup.deploy.facts` reports two keys
      for `root`, and `git grep` for the private half finds nothing.
- [ ] 1.3 Add `git` to the host's package set; it is measured absent today and
      the clone step needs it.
      — Verify: `bin/devenv eval machines.netcup.build.nixos` succeeds and the
      evaluated `environment.systemPackages` contains `git`.
- [ ] 1.4 Make the host-side invocation's `sshOpts` point at the loopback key's
      path without disturbing the workstation's `sshOpts` (design D4). Use the
      `-O` override at invocation time rather than a second declaration (D2).
      — Verify: `bin/devenv machines info` still lists exactly one machine whose
      declared target is the public address.
- [ ] 1.5 Run the full eval gate on the workstation, with no host contact:
      `bin/devenv machines info`; `bin/devenv machines check netcup`;
      `bin/devenv eval machines.netcup.build.nixos`.
      — Verify: all three exit 0. `check` still reports
      `access-analysis-incomplete` (risk R8, pre-existing, not a failure).

## 2. Settle the vault question before anything runs on the host (no host contact)

- [ ] 2.1 Measure the wholesale provider override (design D3's rejected-but-open
      alternative) in a scratch copy outside the repository: run
      `machines info` with `SECRETSPEC_PROVIDER` pointed at a value-bearing
      provider and the 1Password token unset, and check whether
      `install.secrets` still resolves `TS_AUTH_KEY`.
      — Verify: the command's exit code and the error text, recorded verbatim;
      a scratch directory under `/tmp`, never the repository.
- [ ] 2.2 Decide between the credential-at-rest route and the provider route
      against 2.1's result, and write the decision into `design.md`'s D3 and the
      open questions, replacing the one that is not chosen.
      — Verify: `design.md` names one route as chosen and states what the other
      cost; no artifact still lists it as undecided.
- [ ] 2.3 Record which remote and which branch or bookmark the host will clone
      (open question 1). This is an operator decision with no evidence in the
      tree; ask rather than infer.
      — Verify: the answer appears in the procedure document written in 8.1.

## 3. Bootstrap the host from the workstation (first write to the host)

- [ ] 3.1 Deploy this change from the workstation — the only ordering that
      works, because the host cannot run `devenv` until 1.1 lands (design D7).
      Run it in an operator-visible pane per `netcup-operations`.
      — Verify: the pane's session identifier is reported, and
      `bin/devenv machines status netcup` shows the operation succeeded rather
      than rolled back.
- [ ] 3.2 Confirm the change did not weaken the public path.
      — Verify: the operator key still logs in over the public address, and
      `bin/devenv eval machines.netcup.deploy.facts` still reports the firewall
      enabled with port 22 as the only allowed TCP port and no port ranges.

## 4. Isolated host probes, no devenv involved (read-only)

Each probe settles one precondition independently, so a later failure can be
attributed rather than guessed at.

- [ ] 4.1 Confirm the nix features are available non-interactively, with no
      `NIX_CONFIG` in the environment.
      — Verify: `nix flake --help` (or any `nix-command` subcommand) runs on the
      host as a non-interactive process, from `ssh root@152.53.92.126 '…'`.
- [ ] 4.2 Confirm the loopback identity works with no agent and no prompt.
      — Verify: `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i <host key>
      root@localhost id -u` prints `0`.
- [ ] 4.3 Confirm the loopback target is a usable store.
      — Verify: `nix store info --store ssh://root@localhost` reports a store
      with a trusted connection, rather than failing to start the SSH
      connection.
- [ ] 4.4 **Settle R1: the copy-to-self step.** Run the transfer in isolation
      against a path already present, before any deploy depends on it.
      — Verify: `nix copy --to ssh://root@localhost /nix/store/$(readlink -f
      /run/current-system)` exits 0 and transfers nothing. If it refuses, stop
      and record it: design D1's chosen route is invalid and the fallback in D1
      costs the plan, the watchdog and `status`.

## 5. The checkout and the pinned toolchain on the host

- [ ] 5.1 Create the remote and publish: a branch or jj bookmark at the current
      revision, pushed per 2.3's answer. The repository is jj-colocated in
      detached HEAD with no bookmarks today, so there is nothing to push yet.
      — Verify: `git remote -v` shows the remote; the branch or bookmark resolves
      to the same commit as the working copy's tip.
- [ ] 5.2 Clone to `/home/hbohlen/nix` on the host. `git` only — jj is not needed
      to build or deploy.
      — Verify: the host's `git rev-parse HEAD` equals the pushed revision.
- [ ] 5.3 Obtain the pinned toolchain from `devenv.cachix.org` and root it in the
      checkout, using `bin/devenv`'s documented command. It is measured present
      in that cache, so this is a download and not a Rust build.
      — Verify: `bin/devenv --version` on the host reports 2.4.0 or newer, and
      the substituted path is the same store path the workstation uses.
- [ ] 5.4 Build the system on the host with the workstation unreachable.
      — Verify: `bin/devenv build machines.netcup` on the host prints a
      `nixos-system-netcup-*` path with the same name the workstation produces,
      and no remote builder participated.

## 6. The SecretSpec profile on the host

- [ ] 6.1 Establish the route chosen in 2.2: either the credential at rest
      (root-only `0600`, read-only scope) or the provider override.
      — Verify: the file's mode and owner are read back, and nothing prints the
      credential's value.
- [ ] 6.2 Confirm a non-interactive `machines` invocation resolves the profile on
      the host.
      — Verify: `bin/devenv machines info` at `/home/hbohlen/nix` on the host
      exits 0 unattended, listing the netcup machine.
- [ ] 6.3 Confirm install-time delivery was not traded away and no new secret
      value was written.
      — Verify: `secretspec.toml` still declares `TS_AUTH_KEY` and the Machine's
      `install.secrets` entry is unchanged; a sweep of the paths this change
      added finds no secret value.

## 7. The self-deploy loop

- [ ] 7.1 Run the read-only machine operations against the loopback target.
      — Verify: `bin/devenv machines check netcup -O
      machines.netcup.target.host:string root@localhost` and `machines status`
      with the same override both exit 0 and report the host's facts.
- [ ] 7.2 Run the **no-op** self-deploy: the host currently matches its
      declaration (`Closure: +0 / -0`), so nothing new is started. This is the
      end-to-end proof and risk R2's first exercise.
      — Verify: `bin/devenv machines deploy netcup -O
      machines.netcup.target.host:string root@localhost --yes` completes, and
      `machines status netcup` reports succeeded, not rolled back.
- [ ] 7.3 Confirm the running system is the one built on the host.
      — Verify: `readlink -f /run/current-system` on the host equals the store
      path 5.4's build produced.
- [ ] 7.4 Deploy a real change from the host and observe it applied.
      — Verify: the changed fact is read back on the running host, and
      `machines status` reports succeeded.
- [ ] 7.5 Test the rollback deliberately, with the tailnet reachable (risk R3).
      Do not run this until 7.2 and 7.4 pass.
      — Verify: after deploying a configuration whose activation fails, the
      previously running system is restored, the host answers SSH, and
      `machines status` reports the failure and its outcome. Then correct it and
      deploy again successfully, with no re-image.

## 8. Procedure and scripts

- [ ] 8.1 Write the procedure document for the host-side loop — clone, edit,
      build, deploy, verify — naming each step and the command that verifies it,
      including which remote to use (2.3) and that edits are pushed from the host
      so the checkout cannot drift (risk R5).
      — Verify: every step in the document names a command; a reader can follow
      it without consulting this change.
- [ ] 8.2 Add verification scripts in the shape `scripts/` already uses, and wrap
      host-touching ones for an operator-visible pane per `netcup-operations`.
      — Verify: each script is runnable and reports its verdict and the pane's
      session identifier; no script prints a secret value.
- [ ] 8.3 Add a drift check comparing the host's checkout revision with the
      pushed revision, so a hand-edited host copy is visible rather than silent.
      — Verify: the check passes on a freshly cloned host and fails after a
      deliberate uncommitted edit on it.

## 9. Validation and promotion

- [ ] 9.1 Re-read every scenario in `specs/netcup-self-deploy/spec.md` against
      the evidence collected above; for each, either name the command output that
      proves it or mark it as not yet provable, with the reason.
      — Verify: no scenario is left uncited and unremarked.
- [ ] 9.2 Run `openspec validate add-netcup-self-deploy --strict --json` and read
      the `issues` array rather than asserting it is empty; an INFO note is a
      style signal, an `error` is a failure.
      — Verify: `valid: true` with no `error`-level issue.
- [ ] 9.3 Promote: `openspec archive add-netcup-self-deploy`, then confirm the
      capability lands at `openspec/specs/netcup-self-deploy/`.
      — Verify: `openspec list --specs` contains `netcup-self-deploy` with its
      requirement count, and the change directory is under `archive/`.
