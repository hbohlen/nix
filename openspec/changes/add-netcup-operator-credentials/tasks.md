# Tasks: add-netcup-operator-credentials

Ordering rule from the repo: nothing that touches the live host runs until the
eval/check gates in group 2 pass, and every host-touching task runs through
`scripts/bb-pane-run.sh` (a visible pane, session id reported) per
`netcup-operations`. Every task names the command that verifies it.

## 1. Local declarations (no evaluation, no host contact)

- [ ] 1.1 Write the `gh` wrapper in `hosts/netcup/operator.nix`: a
      home-manager package that resolves `GH_TOKEN` through SecretSpec for one
      invocation and `exec`s the real `gh` — referencing the real `gh` by store
      path, and passing all arguments through unchanged. Add it to
      `home.packages` so `PATH` resolves it ahead of `pkgs.gh`.
      Verify: `grep -n 'writeShellScript\|gh' hosts/netcup/operator.nix` shows
      the wrapper; `grep -n 'hosts.yml\|gh auth login' hosts/netcup/operator.nix`
      returns nothing (no persistence path is written).
- [ ] 1.2 Write the activation seed for `hbohlen`'s vault credential: copy a
      root-owned source into `~/.config/op-sa-token` as `hbohlen`-owned `0600`
      on every activation (the `loopbackKey` pattern, design D2). The source is
      a path **string**, never a Nix path literal.
      Verify: `grep -n 'op-sa-token' hosts/netcup/operator.nix` shows the seed;
      `grep -nE '\./secrets|path literal' hosts/netcup/operator.nix` shows no
      Nix path literal for the secret.
- [ ] 1.3 Write `scripts/operator-credential-seed.sh` (workstation-side, pane
      wrapper aware): materialize the root-owned source that activation copies,
      by writing the service-account token to its path on the host without
      printing it (stdin pipe, never argv).
      Verify: `bash -n scripts/operator-credential-seed.sh`; the script never
      `echo`es the value (`grep -c 'echo.*TOKEN'` → 0).
- [ ] 1.4 Add the check for the operator's credential to
      `scripts/operator-env-verify.sh`, as `hbohlen` (not root): `secretspec
      check` resolves both secrets, bare `gh auth status` reports the account,
      `~/.config/gh/hosts.yml` is absent, the credential is `hbohlen` `0600`,
      and root's file is unchanged.
      Verify: `bash -n scripts/operator-env-verify.sh`;
      `grep -n 'hosts.yml' scripts/operator-env-verify.sh` shows the
      absence check.

## 2. Eval and build gates (local; must pass before any host touch)

- [ ] 2.1 `SECRETSPEC_REASON="eval gate" ./bin/devenv machines info` exits 0 and
      still lists `nixos, home-manager`.
      Verify: exit 0; the role line is captured in the task's output note.
- [ ] 2.2 Build the home-manager output:
      `./bin/devenv build machines.netcup.build.home-manager` → exit 0.
      Verify: exit 0 and a store path is printed.
- [ ] 2.3 Prove the wrapper is the `gh` on the built home's `PATH` and the real
      `gh` is still reachable by absolute path:
      `nix-store -qR <2.2's path> | grep gh` and inspect the built env's `bin`.
      Verify: the `bin/gh` in the built home resolves to the wrapper, and the
      referenced `pkgs.gh` remains at its own store path.
- [ ] 2.4 `SECRETSPEC_REASON=… ./bin/devenv build machines.netcup` → exit 0
      (the system half must be unaffected by this change).
      Verify: exit 0.
- [ ] 2.5 `openspec validate add-netcup-operator-credentials --strict` → passes
      with the two spec files as written.
      Verify: exit 0.

## 3. Host checks and application (all pane-wrapped)

- [ ] 3.1 **Read-only pre-deploy probe** (check gate for the deploy): confirm
      the host still has no `hosts.yml` and no `GH_TOKEN`, and record root's
      credential mode/owner/digest prefix — the baseline this change must not
      move.
      Verify: report the pane session id; record the baseline values.
- [ ] 3.2 **Seed the source only** (pane): run
      `scripts/bb-pane-run.sh --title "operator credential seed" --
      ./scripts/operator-credential-seed.sh`; report the pane session id.
      Verify: the source file exists root-owned `0600`; its value is never
      printed.
- [ ] 3.3 Sync the host's checkout per `docs/self-deploy-netcup.md`
      (workstation push → host pull), then verify host revision == pushed
      revision.
      Verify (pane): `scripts/self-deploy-drift.sh` reports no drift, with its
      pane session id.
- [ ] 3.4 **Deploy** (pane): `scripts/bb-pane-run.sh --title "operator
      credential deploy" -- ./scripts/self-deploy-host.sh` — system role first,
      then home-manager activates as `hbohlen` and seeds the credential; report
      the pane session id.
      Verify: exit 0 and `outcome: succeeded`.
- [ ] 3.5 **Post-deploy verification** (pane, one script run):
      `scripts/bb-pane-run.sh --title "operator credential verify" --
      ./scripts/operator-env-verify.sh` — as `hbohlen`: `secretspec check`
      resolves both secrets; bare `gh auth status` reports the account;
      `~/.config/gh/hosts.yml` absent; credential `hbohlen` `0600`; root's file
      unchanged; root-side `machines info` still exits 0.
      Verify: script exits 0; pane session id reported alongside the verdict.
- [ ] 3.6 Re-check the loop still works after the operator's credential lands
      (pane): `scripts/self-deploy-preflight.sh` → all gates green, session id
      reported.
      Verify: script exits 0.

## 4. Documentation and closure

- [ ] 4.1 Record the posture: amend `docs/handoff-followups.md` §6 (the "which
      token" mechanics) so the operator account — not only root — is named as
      the holder of the credential, and the `hosts.yml` non-goal and its flip
      are written down.
      Verify: `grep -n 'hosts.yml\|operator' docs/handoff-followups.md` shows
      the update.
- [ ] 4.2 Record the closures: handoff ledger rows for the operator credential
      and the `gh` wrapper, and the D4/D5 analysis pointer.
      Verify: `grep -n 'operator credential\|wrapper' docs/handoff-followups.md`
      shows the updated rows.
- [ ] 4.3 Final validation: `openspec validate --all --strict` → all specs and
      this change pass.
      Verify: exit 0.
