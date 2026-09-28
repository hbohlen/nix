# Design: add-netcup-agent-tooling

## Context

The operator account `hbohlen` on netcup is a home-manager role on the
`machines.netcup` Machine (`add-netcup-operator-env`; `hosts/netcup/operator.nix`),
activated as `hbohlen` after the system role. It carries `devenv` (derived from
the locked `devenv:` input), `gh`, and a `~/projects` mkdir. It carries no agent
tooling. This change adds two executables, `hermes` and `herdr`, and the
substituter the host needs to obtain them without compiling them.

Relevant state, each fact with the command or file it came from. Everything
marked **(measured)** was run on 2026-09-28 against the versions named; anything
unmeasured is marked so, because this repository cites measurements rather than
assumptions.

| Fact | Source / command | Value |
|---|---|---|
| The flake resolves and locks | `nix flake metadata github:numtide/llm-agents.nix` (workstation, nix 2.34.7) | rev `e28ea84e78517e5d05ae0c399da00e848e207261`, last modified 2026-09-28 00:33:25 |
| Its nixpkgs pin | same command, input graph | `NixOS/nixpkgs` `3181085` (2026-09-27) |
| This Machine's nixpkgs | `devenv.lock`, `nixpkgs` node | `cachix/devenv-nixpkgs/rolling` `c2f38fe7…`, whose `nixpkgs-src` is `NixOS/nixpkgs` `c7def046` |
| The two packages exist and their shape | `packages/{hermes-agent,herdr}/package.nix` in llm-agents (fetched 2026-09-28) | `hermes-agent` `2026.9.14`, licence MIT, `mainProgram = hermes`; `herdr` `0.9.1`, licence `asl20`, `mainProgram = herdr`; both `x86_64-linux` |
| Her whole build weight | `packages/hermes-agent/package.nix` | a `buildPythonApplication` with two `buildNpmPackage` frontends (Ink TUI + Vite web), two Rust/PyO3 extensions built with `maturin` (`nemo-relay`, `firecrawl-anydoc`), and a `python3.withPackages` closure |
| herdr build weight | `packages/herdr/package.nix` | `rustPlatform.buildRustPackage` whose `build.rs` shells out to `zig` for vendored `libghostty-vt` |
| Neither is in the declared caches | by name against `cache.nixos.org` / `devenv.cachix.org` | absent — these packages are only published to the Numtide cache |
| The cache and key | llm-agents README (fetched 2026-09-28) | `https://cache.numtide.com`; key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=`; "automatically configured when this flake is used directly" — **not** when it is an input |
| Following nixpkgs costs the cache | llm-agents README, "Using Nix Flakes" | "If you set `llm-agents.inputs.nixpkgs.follows = "nixpkgs"`, your `nixpkgs` must also track `nixpkgs-unstable` and be reasonably current — using a stable release branch … **will** break eventually. Omitting `follows` … lets you pull pre-built binaries" |
| The host's substituters today | `hosts/netcup/self-deploy.nix` | `cache.nixos.org` (nixpkgs default) + `https://devenv.cachix.org` (`lib.mkAfter`) |
| Host trust | `hosts/netcup/self-deploy.nix`; live host | `trusted-users = root` only — a non-root client substituter is silently dropped |
| Workstation trust | `nix config show` (Determinate Nix 3.21.1 / nix 2.34.7) | `trusted-users = root hbohlen`; so a per-invocation flag **is** honoured here |
| The role receives `inputs` | devenv 2.4.0 `src/modules/machines.nix:211/208` | `extraSpecialArgs = { inherit inputs self; }`, `pkgs = inputs.nixpkgs.legacyPackages.<system>` — so `inputs.llm-agents` is reachable from `operator.nix` exactly as `inputs.devenv` already is |
| home-manager has no rollback | `hosts/netcup/operator.nix`; `netcup-self-deploy` | a failed HM activation leaves the applied system generation active |
| The vault already holds a hermes item | `docs/handoff-followups.md` §5 | `HERMES_API_SERVER_KEY` is in `dev`; `secretspec.toml` declares only `TS_AUTH_KEY` and `GH_TOKEN` |

The third-milestone context is unchanged: the repository is public, the host is
live and rebuilt only through the self-deploy loop, and the workstation is the
place edits are authored.

## Goals / Non-Goals

**Goals:**

- `hermes` and `herdr` on `hbohlen`'s `PATH` on the host, sourced from a pinned
  `llm-agents` input, deployed by the existing loop and surviving a re-image the
  same way the rest of the operator environment does.
- The host declares the cache those packages come from, so obtaining them on
  either build machine is a download rather than a Rust/npm/zig build.
- Spec truth: a new `netcup-agent-tooling` capability, and a stated, additive
  extension of `netcup-self-deploy`'s nix-preconditions surface.

**Non-Goals:** everything named in the proposal's non-goals. Repeated here
because they are design boundaries, not oversights: no service/linger/timer, no
provider credential in the manifest, no `herdr` integration wiring, no `hermes`
skills/config wiring, no `follows`, no overlay, no devshell package, no
`trusted-users` widening, no hardening.

## Decisions

| # | Decision | Chosen | Rejected |
|---|---|---|---|
| D1 | Which role carries the tools | the existing home-manager role (`home.packages`), via a new `hosts/netcup/agents.nix` imported by `operator.nix` | `environment.systemPackages` in the system role (puts agent binaries on every account; `hermes` needs `hbohlen`'s writable `HOME`, and the tools are user-level by nature); folding them into `operator.nix` inline (the file is about devenv/gh/projects; the tailnet/self-deploy/operator split is the repository's pattern for "small config, large justification") |
| D2 | How the input is declared and pinned | a hand-added `llm-agents` input in `devenv.yaml`, **not** following `nixpkgs`, frozen in `devenv.lock` | `follows: nixpkgs` (README-measured to cost the cache hits and to require an unstable, current nixpkgs — this Machine's is devenv-nixpkgs/rolling, a different revision); `overlays.shared-nixpkgs` (a Machine may not set `nixpkgs.overlays` — the same externally-created-instance failure recorded for `nixpkgs.config`; and the cache only hits when the nixpkgs revision matches theirs); `nix run github:…` at use time (not declarative; not on `PATH`; not re-image-proof) |
| D3 | How the host gets the packages | declare `https://cache.numtide.com` + its key in `nix.settings`, `lib.mkAfter`, beside `devenv.cachix.org` | relying on the flake's own `nixConfig` (not honoured for an input — README); per-invocation `--option extra-substituters` on the host (silently dropped for untrusted users; host `trusted-users` is `root`, and the system role is what fails the check anyway); widening `trusted-users` (a permanent privilege grant for a cache problem — `netcup-agent-runner` already declines this default) |
| D4 | How the **first** build substitutes, before either machine declares the cache | a documented one-time operator action on the workstation (add the same cache + key to its `nix.conf`) **plus** an eval/build gate that fails loudly if the closure would compile the packages from source | editing `bin/devenv` to inject `NIX_CONFIG`/`--option` into every invocation (changes the semantics of a script whose single job is to pin one version, and hides an operator precondition in a wrapper); pre-seeding the store by hand with explicit flags (fragile, unverifiable, does not survive GC) — the ambient declaration is the same shape as materializing the vault identity: an operator precondition the repo documents rather than encodes |
| D5 | Scope | `PATH` only — install, do not start | a `systemd.services.*` unit or a lingered user unit (that is `netcup-agent-runner`'s decision, deliberately deferred until a concrete runner exists); declaring `HERMES_API_SERVER_KEY` now (its field and consumer are not yet defined, and `hermes` is not useful without a model config this change does not design) |
| D6 | Module placement | `hosts/netcup/agents.nix`, imported by the home-manager role's module | see D1 |
| D7 | Update rhythm | the input is frozen at the locked rev; update by name only (`devenv inputs update llm-agents`), never bare `devenv update` | floating on the default branch (the repository's `devenv.yaml` comments already warn what bare `devenv update` does to the `devenv` node; the same hazard applies here) |

## Risks / Trade-offs

- **[R1] A second nixpkgs enters the closure graph.** Not following nixpkgs means
  the two packages and all their dependencies (a second `python3`, `rust`, `node`,
  `glibc`-linked closure) are built against llm-agents' `nixpkgs` `3181085`, while
  the system stays on `devenv-nixpkgs/rolling`. → **Accepted deliberately** and
  made spec-visible: it is the price of the cache hits (D2), and the alternative
  (`follows`) is README-measured to break eventually and lose the cache. A task
  measures the closure size delta so the cost is a number, not a surprise.
- **[R2] Eval cost: selecting one attribute from `packages.<system>` forces the
  availability predicate — and therefore `.meta` — for every package in the flake,
  plus a second `import nixpkgs`.** This lands on every `devenv machines`
  invocation on both machines, including the read-only ones and the self-deploy
  loop's. → Unmeasured; a check task times `machines info` and
  `eval machines.netcup.build.nixos` before and after. If the cost is
  unacceptable, the fallback is documented here: pin a commit of llm-agents and
  accept the eval, or lift the two derivations into this repo (a larger change).
- **[R3] A cache miss means a very long build, on whichever machine builds.** The
  self-deploy loop builds on the host; a workstation deploy builds on the
  workstation. Both would compile npm + two Rust/PyO3 extensions + zig/libghostty.
  → The build gate (D4) asserts substitution before any host touch; the preflight
  fails loudly rather than silently starting a multi-hour build at deploy time.
- **[R4] home-manager still has no rollback** (R1 of `add-netcup-operator-env`,
  unchanged). Adding packages does not change the activation risk profile — the
  packages are symlinks and the build is the expensive part, which happens before
  activation — but the posture is restated so nobody reads this change as having
  improved it. → The system role still activates first; recovery remains
  "correct the role and deploy again".
- **[R5] Supply chain: a foreign flake and a foreign binary cache.** → The input is
  pinned by `devenv.lock` (a revision, not a branch), and the cache's public key is
  a declared trust anchor in `nix.settings` alongside the two already declared.
  The packages are free software (MIT / Apache-2.0); no `allow_unfree` change is
  needed.
- **[R6] Merge collision with the in-flight `add-netcup-operator-env`.** That
  change already modifies `netcup-self-deploy`'s "nix preconditions" requirement
  (adding the `devenv.cachix.org` scenario). Editing the same requirement block
  here would collide at archive time. → This change **adds** a distinct
  requirement instead of modifying that one. Whichever change archives first, the
  other's delta applies to an untouched block.
- **[R7] `hermes` installed but unusable.** Without a model provider and skills
  wiring it does nothing. → Stated as a non-goal, so the gap is a decision rather
  than a defect; the follow-up (declaring `HERMES_API_SERVER_KEY` and pointing
  `~/.hermes/skills` at the repository's `.agents/skills`) is named in Open
  Questions.
- **[R8] The packages could be platform-unavailable** if the flake ever drops
  `x86_64-linux`. → Both list it today; the build gate would fail loudly rather
  than ship an empty profile.

## Migration Plan

1. **Local, no host contact.** Hand-add the `llm-agents` input to `devenv.yaml`
   (comments intact). Write `hosts/netcup/agents.nix`; add its `imports` to
   `operator.nix`; add the numtide substituter + key to `hosts/netcup/self-deploy.nix`
   (`lib.mkAfter`).
2. **Eval gate.** One eval locks the input; assert `devenv.lock` gained an
   `llm-agents` node and no existing node moved. `machines info` and
   `eval machines.netcup.build.nixos` still exit 0.
3. **Build + substitution gate (before any host touch).** Build the machine (and
   the home-manager output), timing `machines info` before/after. Build
   `hermes-agent` and `herdr` with build logs and assert the numtide cache
   supplied them (no `building` lines for their inputs). If this fails, stop —
   the workstation's `nix.conf` needs the cache before a deploy is safe.
4. **First application.** Deploy over the existing loop: workstation push → host
   pull → host-side `machines deploy` (per `docs/self-deploy-netcup.md`), so the
   host's own declared cache is exercised. Fallback: the workstation's public root
   path, with the workstation cache declared (D4).
5. **Verify.** `hermes --version` and `herdr --version` as `hbohlen`;
   `nix config show` on the host lists numtide; a non-root substitution probe;
   `machines status netcup` reports `succeeded`; `scripts/operator-env-verify.sh`
   still green (its checks are unaffected — this change adds, it does not modify).
6. **Rollback.** The system half rolls back with the system role (the
   `nix.settings` change). The home-manager half has no rollback: undo by removing
   the `imports` entry and the module, then deploying again. No re-image.

## Open Questions

1. **Does the eval cost (R2) stay in single-digit seconds?** First measurement
   answers it; if not, the fallback in R2 is chosen with the number in hand.
2. **Should `HERMES_API_SERVER_KEY` and the skills link be a follow-up now?**
   The vault already holds the item (`handoff` §5); its `secretspec.toml` field
   and the skills-root layout are not decided here. Recommended: a separate change
   once `hermes` is on `PATH` and a session is attempted.
3. **Is `herdr` useful without its integration assets wired?** It ships
   `$out/share/herdr/integrations` for declarative wiring; this change ships the
   binary only. Revisit if the operator runs agents on the host through `herdr`.
4. **Does the second-nixpkgs exception want an ADR?** This repository has none by
   convention; the decision is cheap to state and expensive to reverse (it shapes
   the closure). Flagged, not decided.
