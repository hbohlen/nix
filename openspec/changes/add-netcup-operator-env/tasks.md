# Tasks: add-netcup-operator-env

Ordering rule from the repo: nothing that touches the live host runs until the
eval/check gates in group 2 pass, and every host-touching task runs through
`scripts/bb-pane-run.sh` (a visible pane, session id reported) per
`netcup-operations`. Every task names the command that verifies it.

## 1. Local declarations (no evaluation, no host contact)

- [x] 1.1 Add the `home-manager` input to `devenv.yaml` **by hand** (`devenv
      inputs add` drops every comment): `url: github:nix-community/home-manager`
      with the nested `inputs.nixpkgs.follows: nixpkgs` form, matching
      `homeManagerInputArgs` in devenv 2.4.0's `machines.nix`.
      Verify: `git diff devenv.yaml` shows only this addition and all comments
      intact.
- [x] 1.2 Write `hosts/netcup/operator.nix` (the home-manager module:
      `home.username`/`home.homeDirectory` for `hbohlen`,
      `home.stateVersion = "26.11"`, devenv package derived from the locked
      `devenv:` input via the `devenvPackageFor` recipe, `pkgs.gh`, and the
      `~/projects` mkdir as an activation entry — **not** `home.file`, design
      D9) and wire it as the `home-manager` role block in `devenv.nix`.
      Verify: `grep -n 'home-manager' devenv.nix` shows the role;
      `grep -n 'home.file' hosts/netcup/operator.nix` returns nothing.
- [x] 1.3 Add `GH_TOKEN` to `[profiles.default]` in `secretspec.toml`
      (`providers = ["dev"]`, `ref = { item = "GH_TOKEN", field = "credential" }`,
      a description — no value) and rewrite the stale "the service account is
      READ-ONLY … nothing in this repository writes to the vault" comment per
      handoff §9/Q8.
      Verify: `grep -n 'GH_TOKEN' secretspec.toml` shows the entry;
      `grep -c 'READ-ONLY' secretspec.toml` reflects the corrected text.
- [x] 1.4 Declare the cache in the **system** role: add
      `nix.settings.substituters` and `nix.settings.trusted-public-keys` for
      `https://devenv.cachix.org` (key `devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=`)
      to `hosts/netcup/self-deploy.nix`, next to the existing
      `experimental-features` declaration, with the measured rationale (untrusted
      client substituters are silently dropped).
      Verify: `grep -n 'devenv.cachix.org' hosts/netcup/self-deploy.nix`.

## 2. Eval and build gates (local; must pass before any host touch)

- [x] 2.1 Lock the new input and prove nothing else moved:
      `./bin/devenv eval machines.netcup.deploy.facts > /dev/null` (or any eval),
      then verify `devenv.lock` gained a `home-manager` node with a resolved rev
      and `follows` → `nixpkgs`, **and** the `devenv` node still reads
      `b904dcb51fe48c30db250038241507f60752f222`.
      Verify: `python3 -c "…print(json.load(open('devenv.lock'))['nodes']['home-manager'])"`
      and `git diff devenv.lock` shows no change to existing nodes.
- [x] 2.2 `SECRETSPEC_REASON="eval gate" ./bin/devenv machines info` exits 0
      (profile now resolves `GH_TOKEN` + `TS_AUTH_KEY`) and its output records
      how roles render — this resolves design open question 3: if it does **not**
      show `home-manager` alongside `nixos`, amend the `netcup-machine` delta and
      proposal before archive instead of shipping a false scenario.
      Verify: exit 0; the role line is captured in the task's output note.
- [x] 2.3 `SECRETSPEC_REASON=… ./bin/devenv eval machines.netcup.build.nixos`
      prints one store path beginning `nixos-system-netcup-`.
- [x] 2.4 Build the home-manager output:
      `./bin/devenv build machines.netcup.build.home-manager` (confirm the attr
      first with `./bin/devenv eval machines.netcup.build --json` if the name
      differs). Verify: exit 0 and a store path is printed.
- [x] 2.5 Prove the pinned package, not `pkgs.devenv`, is in the closure:
      `nix-store -qR <2.4's path> | grep devenv` shows `devenv-wrapped-2.4.0`
      and no `devenv-2.3.1`, and running that referenced `bin/devenv --version`
      reports `2.4.0` — the same base version as `./bin/devenv --version`
      (`2.4.0+b904dcb`; the `+b904dcb` git metadata is only attached when a
      flake is loaded with rev metadata, which the locked `path:`+narHash load
      of design D2 cannot carry, and the spec scenario asks only for the same
      version). Verify: the grep and the version string.
- [x] 2.6 SecretSpec resolution gates:
      `$(readlink -f .devenv-toolchain)/bin/secretspec check --no-prompt --json`
      (profile resolves, no values printed) and
      `SECRETSPEC_REASON=… secretspec run -- gh auth status` on the workstation →
      `✓ Logged in to github.com account hbohlen`.
- [x] 2.7 Full local build of the system closure:
      `./bin/devenv build machines.netcup` → exit 0 (the deployment gate; design
      Migration Plan step 2).
- [x] 2.8 `openspec validate add-netcup-operator-env --strict` → passes with the
      three spec files as written.

## 3. Host checks and first application (all pane-wrapped)

- [ ] 3.1 **Read-only pre-deploy probe** (check gate for the deploy):
      `scripts/bb-pane-run.sh --title "operator-env preflight" -- ssh -i ~/.ssh/id_ed25519-op-dev -o IdentitiesOnly=yes -o BatchMode=yes hbohlen@152.53.92.126 'command -v runuser || echo NO-RUNUSER; grep -E "substituters|trusted" /etc/nix/nix.conf; ls -ld /home/hbohlen/projects 2>/dev/null || echo NO-PROJECTS-DIR'`
      → report the pane session id; record: runuser presence (design R6),
      current substituters baseline (expected: cache.nixos.org only), whether
      `~/projects` pre-exists (design R7).
- [ ] 3.2 Sync the host's checkout per `docs/self-deploy-netcup.md` (workstation
      push → host pull), then verify host revision == pushed revision.
      Verify (pane): `scripts/self-deploy-drift.sh` reports no drift, with its
      pane session id.
- [ ] 3.3 **Host credential gate** (pane): at the host checkout,
      `./bin/devenv machines info` exits 0 — the host's D3 credential resolves
      the profile including `GH_TOKEN` (design R3). If this fails, stop: the
      self-deploy loop is broken by the declaration and 1.3 must be revisited
      before any deploy.
- [ ] 3.4 **Deploy** (pane): run the routine host-side loop,
      `scripts/bb-pane-run.sh --title "operator-env deploy" -- ./scripts/self-deploy-host.sh`
      (or the documented `./bin/devenv machines deploy netcup -O
      machines.netcup.target.host:string root@localhost` form) → system role
      activates first, home-manager activates as `hbohlen`; report the pane
      session id. Fallback route if the loop is mid-change: the workstation's
      public root path.
- [ ] 3.5 **Post-deploy verification** (pane, one script run):
      `scripts/bb-pane-run.sh --title "operator-env verify" -- ./scripts/operator-env-verify.sh`
      — a new script asserting, per spec scenarios:
      `devenv --version` == `./bin/devenv --version` (2.4.0) as `hbohlen`;
      `gh --version` present; `readlink /home/hbohlen/projects` empty and the
      dir writable by `hbohlen` (create + delete a file);
      `nix config show | grep -c devenv.cachix.org` ≥ 1 **as hbohlen**;
      `nix build --no-link --print-out-paths nixpkgs#hello` as `hbohlen`
      completes (non-root substitution works with no client flags) — the
      tasks file originally named `nix-build -p hello`, which is not a valid
      flag (`-p` belongs to `nix-shell`); see the script header;
      `SECRETSPEC_REASON=… secretspec run -- gh auth status` on the host →
      authenticated;
      `./bin/devenv machines status netcup` → `outcome: succeeded`.
      Verify: script exits 0; pane session id reported alongside the verdict.
- [ ] 3.6 Re-check the loop still works after the new secret is on its path
      (pane): `scripts/self-deploy-preflight.sh` → all gates green, session id
      reported.

## 4. Documentation and closure

- [x] 4.1 Scope the "never bare `devenv`" rule (design R7 trade-off): amend the
      `bin/devenv` header comment and `docs/handoff-followups.md` §6 so the rule
      reads *workstation-only* — on the host, bare `devenv` is the pinned 2.4.0
      the HM role installed, and the two names agree by construction.
      Verify: `grep -n 'workstation' bin/devenv` shows the scoping.
- [x] 4.2 Record the follow-up closures: handoff ledger Q7 (gh on host), Q8
      (GH_TOKEN declared), self-deploy design Q7 (home-manager role decided),
      with the measured substituter mechanism note already in ledger #10.
      Verify: `grep -n 'GH_TOKEN\|home-manager' docs/handoff-followups.md`
      shows the updated rows.
- [x] 4.3 Final validation: `openspec validate --all --strict` → all specs and
      this change pass (repo convention: changes land with `openspec validate`).
