# Tasks: add-netcup-agent-tooling

Ordering rule from the repository: nothing that touches the live host runs until
the eval/check gates in group 2 pass, and every host-touching task runs through
`scripts/bb-pane-run.sh` (a visible pane, session id reported) per
`netcup-operations`. Every task names the command that verifies it.

## 1. Local declarations (no evaluation, no host contact)

- [x] 1.1 Add the `llm-agents` input to `devenv.yaml` **by hand**
      (`devenv inputs add` drops every comment), preserving all comments and the
      existing `devenv`, `disko`, `home-manager` and `nixpkgs` nodes. Do **not**
      add an `inputs.nixpkgs.follows` nesting — the whole point (design D2) is
      that it does not follow.
      Verify: `git diff devenv.yaml` shows only this addition and all comments
      intact; `grep -n 'follows' devenv.yaml` shows nothing under `llm-agents`.
- [x] 1.2 Write `hosts/netcup/agents.nix`: a home-manager module that adds
      `inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.hermes-agent`
      and `…herdr` to `home.packages`, with an `or (throw …)` guard naming the
      missing `llm-agents` input (the `devenv`-derivation guard is the pattern),
      and the justification for sourcing from the input rather than `pkgs`
      (design D2). Wire it with `imports = [ ./agents.nix ]` in
      `hosts/netcup/operator.nix`.
      Verify: `grep -n 'llm-agents' hosts/netcup/agents.nix` shows both packages;
      `grep -n 'agents.nix' hosts/netcup/operator.nix` shows the import.
- [x] 1.3 Declare the substituter in the **system** role: add
      `nix.settings.substituters` and `nix.settings.trusted-public-keys` for
      `https://cache.numtide.com` and its key
      `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=` to
      `hosts/netcup/self-deploy.nix`, `lib.mkAfter` beside the existing
      `devenv.cachix.org` lines, with the measured rationale (the packages are in
      neither declared cache; an untrusted client substituter is silently dropped).
      Verify: `grep -n 'cache.numtide.com\|niks3.numtide.com' hosts/netcup/self-deploy.nix`.

## 2. Eval and build gates (local; must pass before any host touch)

- [x] 2.1 Lock the new input and prove nothing else moved:
      `./bin/devenv eval machines.netcup.deploy.facts > /dev/null` (or any eval),
      then verify `devenv.lock` gained an `llm-agents` node with a resolved rev
      equal to the metadata's `e28ea84e…` (or newer), that it does not `follows`
      `nixpkgs`, and that the `devenv` node still reads
      `b904dcb51fe48c30db250038241507f60752f222`.
      Verify: `python3 -c "…json.load(open('devenv.lock'))['nodes']['llm-agents']"`
      and `git diff devenv.lock` shows no change to existing nodes.
- [x] 2.2 `SECRETSPEC_REASON="eval gate" ./bin/devenv machines info` exits 0 and
      still lists `netcup` with both roles (`nixos`, `home-manager`).
      Verify: exit 0; the role line captured in the task's output note.
- [x] 2.3 `SECRETSPEC_REASON=… ./bin/devenv eval machines.netcup.build.nixos`
      prints one store path beginning `nixos-system-netcup-`.
- [x] 2.4 Build the home-manager output:
      `./bin/devenv build machines.netcup.build.home-manager` → exit 0.
- [x] 2.5 **Measure the eval cost (R2).** Time
      `SECRETSPEC_REASON=… ./bin/devenv machines info` and
      `… eval machines.netcup.build.nixos` before (on the pre-change revision)
      and after, and record both. If the delta is not single-digit seconds,
      record which fallback in the design R2 is chosen — do not proceed silently.
      Verify: the two timings are in the task's output note.
- [x] 2.6 **Substitution gate (design D4) — the gate that makes a deploy safe.**
      Realize both packages and assert the numtide cache supplied them:
      `nix build --no-link --print-build-logs github:numtide/llm-agents.nix#hermes-agent`
      (and `#herdr`), then confirm from the log that they were **copied** from
      `cache.numtide.com` and not `building` for their own derivation. If they
      would be built from source, STOP: the workstation's `nix.conf` needs the
      declared cache (D4) before any deploy.
      Verify: the printed store paths and a log excerpt showing a
      `copying path … from https://cache.numtide.com` line with no `building`
      line for `hermes-agent`/`herdr` or their vendored extensions.
- [x] 2.7 **Measure the closure delta (R1).** Record the size and path count the
      two packages add: `nix path-info -Sh <hermes>` and `<herdr>`, and the
      machine closure's path count before/after
      (`nix-store -qR <system path> | wc -l`). The number is the accepted cost of
      not following nixpkgs.
      Verify: the sizes and counts are in the task's output note.
- [x] 2.8 Full local build of the system closure: `./bin/devenv build machines.netcup`
      → exit 0 (the deployment gate).
- [x] 2.9 `openspec validate add-netcup-agent-tooling --strict` → passes with the
      two spec files as written.

## 3. Host checks and first application (all pane-wrapped)

- [x] 3.1 **Read-only pre-deploy probe** (check gate for the deploy):
      `scripts/bb-pane-run.sh --title "agent-tooling preflight" -- ssh -i ~/.ssh/id_ed25519-op-dev -o IdentitiesOnly=yes -o BatchMode=yes root@152.53.92.126 'grep -E "substituters|trusted" /etc/nix/nix.conf'`
      → report the pane session id; record the substituter baseline (expected:
      `cache.nixos.org` + `devenv.cachix.org`, `trusted-users = root`).
- [x] 3.2 **Host credential gate** (pane): at the host checkout,
      `./bin/devenv machines info` exits 0 — the declaration does not break the
      self-deploy loop's profile resolution (no secret was added, so this should
      be unchanged; verify rather than assume).
- [x] 3.3 **Deploy** (pane): run the routine host-side loop,
      `scripts/bb-pane-run.sh --title "agent-tooling deploy" -- ./scripts/self-deploy-host.sh`
      → system role applies the `nix.settings` change first, home-manager then
      symlinks the two packages as `hbohlen`; report the pane session id.
- [x] 3.4 **Post-deploy verification** (pane, one run): a script (new, or an
      extension of `scripts/operator-env-verify.sh`) asserting, per spec
      scenarios:
      `hermes --version` and `herdr --version` as `hbohlen` report a version;
      `nix config show | grep -c cache.numtide.com` ≥ 1 **as hbohlen**;
      `nix build --no-link --print-out-paths nixpkgs#hello` as `hbohlen` still
      completes (the existing cache did not regress);
      a numtide-provided path realizes as `hbohlen` with no client flags;
      `./bin/devenv machines status netcup` → `outcome: succeeded`;
      `scripts/operator-env-verify.sh` still exits 0 (this change adds; it must
      not break the checks already there).
      Verify: script exits 0; pane session id reported alongside the verdict.

## 4. Posture checks and closure

- [x] 4.1 The access posture is unchanged (eval):
      `SECRETSPEC_REASON=… ./bin/devenv eval machines.netcup.deploy.facts` shows
      firewall enabled, `allowedTCPPorts = [ 22 ]`, `allowedTCPPortRanges = [ ]`,
      and sshd settings identical to before the change.
- [x] 4.2 No service, timer or linger was introduced:
      `grep -rniE 'systemd\.(services|timers)|linger' hosts/netcup/agents.nix` returns
      nothing, and the evaluated system's unit set is unchanged except for the
      `nix.settings` content.
- [x] 4.3 The deploy posture is unchanged: `grep -n 'home-manager' devenv.nix`
      still shows one role on the one Machine, and `git diff devenv.nix` is empty.
- [x] 4.4 Record the follow-up closures in `docs/handoff-followups.md`: the
      vault's `HERMES_API_SERVER_KEY` consumer is named as an open follow-up (not
      declared here), and note the second declared cache.
      Verify: `grep -n 'HERMES_API_SERVER_KEY\|cache.numtide.com' docs/handoff-followups.md`.
- [ ] 4.5 Final validation and closure: `openspec validate --all --strict` → all
      specs and this change pass; archive when the host is verified.
