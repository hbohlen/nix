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
- [ ] 2.3 Record which remote and which branch or bookmark the host will clone
      (open question 1). This is an operator decision with no evidence in the
      tree; ask rather than infer.
      — Verify: the answer appears in the procedure document written in 8.1.

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
