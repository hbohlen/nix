# Design: add-netcup-operator-env

## Context

`machines.netcup` today has exactly one role (`nixos`). The operator account
`hbohlen` exists on the host (declared in `hosts/netcup/default.nix`) but owns no
environment: no `devenv` on `PATH` — only `bin/devenv`, whose gcroot
`.devenv-toolchain` is gitignored and was materialized by hand on each machine —
no `gh`, no `~/projects`, and nothing user-level that would survive a re-image
except what the system role declares.

Relevant state, each fact with the command and version it came from (measured
2026-09-28 unless noted):

| Fact | Command / source | Value |
|---|---|---|
| `pkgs.devenv` from this Machine's nixpkgs | `nix eval --impure --expr '… (import (builtins.getFlake "github:cachix/devenv-nixpkgs/rolling") { system = "x86_64-linux"; }).devenv.version'` | `"2.3.1"` — **no `machines` subcommand** (rolling HEAD; `devenv.lock` pins devenv-nixpkgs `c2f38fe7f9e04d9aadd354d380f2bd40531d9737`) |
| Machines module source | `devenv.lock` `devenv` node rev | `b904dcb51fe48c30db250038241507f60752f222` = devenv **v2.4.0**; read from `/nix/store/n1zz8rrfw0sx39dizqj4a6468lxga71q-source/src/modules/machines.nix` |
| home-manager backing input | same file, `homeManagerInputArgs` | `url = github:nix-community/home-manager`, `follows = [ "nixpkgs" ]`; a missing input raises devenv's targeted `_mkInputError` naming `machines.<name>.home-manager` |
| Activation-user handling | same file, `buildHomeManagerToplevel` | driver: run as target user directly → `runuser -u <user>` when uid 0 → `sudo -H -u <user>` → hard error; upstream comment: "commonly root for a combined NixOS + home-manager deployment" |
| Pinned package derivable from the *existing* input | same file, `devenvPackageFor` (internal; used at line 151 for target-side SecretSpec) | `inputs.devenv.sourceInfo.narHash` → `builtins.getFlake "path:…?narHash=…"` → `packages.<system>.devenv`. **Not a public option** — we replicate the ~15 lines |
| Workstation trust | `nix config show \| grep -E 'trusted-users\|^substituters'` (Determinate Nix 3.21.1 / nix 2.34.7) | `trusted-users = root hbohlen`; substituters `cache.nixos.org`, `install.determinate.systems` |
| Host trust | `grep -E 'substituters\|trusted' /etc/nix/nix.conf` (nix 2.34.8; measured 2026-09-27, handoff §6 + self-deploy design table) | `trusted-users = root`; substituters **cache.nixos.org only** |
| Untrusted client substituters are **silently dropped** | workstation, same nix generation: `sudo -n -u nobody env HOME=/ nix-store -r /nix/store/1111…1111-fake --option substituters https://example.invalid` (and an `--option extra-substituters` variant) vs the identical run as root | untrusted: bogus cache **never contacted**, generic "no substituter that can build it"; root: contacted, 5 retry attempts. **`nix … config show` is an invalid instrument** — it prints the setting as applied without negotiating trust |
| `home.stateVersion` is an enum | HM option reference (declared in HM `modules/misc/version.nix`) | `one of "18.09" … "26.05", "26.11"` — `"26.11"` is valid and matches this repo's `system.stateVersion = "26.11"` |
| `GH_TOKEN` vault item | handoff §9 (2026-09-28) | `dev` item id `2kwzmxoczu2ztp7tb2xowciugu`, category `API_CREDENTIAL`, field `credential`, classic `ghp_` PAT; Q8 records ref addressing as measured-working |
| `op` / `gh` on host | `hosts/netcup/self-deploy.nix` | `systemPackages = [ pkgs.git pkgs._1password-cli ]` (op 2.39.0); **`gh` absent** |
| SecretSpec on path | `openspec/config.yaml`, `devenv.yaml` | secretspec 0.21.0, `require_reason = true`, provider `dev`, profile `default`; every `machines` invocation resolves the whole profile |

Documented constraints carried from the machines docs: the system role
activates first, then home-manager as `home.username`; `install` provisions
**only** NixOS; home-manager has **no automatic rollback**; a home-manager
failure leaves the NixOS deployment applied.

## Goals / Non-Goals

**Goals:**

- `hbohlen` gets a declarative user environment: pinned devenv (2.4.x, equal to
  `bin/devenv`), `gh`, a `~/projects` root — carried by a new `home-manager`
  role on the existing Machine and deployed by the existing loop.
- `GH_TOKEN` becomes resolvable through the SecretSpec profile so `gh` can
  authenticate **per use** with no token at rest anywhere.
- Non-root builds on the host substitute from `devenv.cachix.org` because the
  host *declares* the cache, not because a caller passed a flag the daemon
  silently drops for untrusted users.
- Spec truth: rollback scoped to the system role, both roles enumerable, new
  `netcup-operator-env` capability.

**Non-Goals:** as stated in proposal.md — the planning root stays on the
workstation; the agent-runner service model is handoff ledger #10;
`nix.conf access-tokens` delivery for GitHub rate limits is its own change once
the need is measured; `bin/devenv`'s tag vs `devenv.lock` pin consolidation is
deferred (two pins, both documented, both on the same release today);
workstation tooling stays unmanaged; no hardening, no `oci`, no content in
`~/projects`.

## Decisions

| # | Decision | Chosen | Rejected |
|---|---|---|---|
| D1 | How the user environment is deployed | a `home-manager` role on the existing `machines.netcup`, same `target.host` and `sshOpts`, activated after the system role by devenv's `runuser`/`sudo` driver | a second `machines.*` declaration for the same host (two declarations drift — the objection self-deploy D2 already recorded); a standalone home-manager CLI/flake (second toolchain, second activation surface, imperative) |
| D2 | Where the devenv **package** comes from | replicate devenv's own `devenvPackageFor` in our module: `inputs.devenv.sourceInfo.narHash` → `builtins.getFlake "path:…?narHash=…"` → `.packages.${system}.devenv` — **derived from the already-locked `devenv:` input, no new pin** | a new `devenv-cli` input pinned `v2.4.0` (a **third** pin beside bin/devenv's tag and the module input — the drift devenv.yaml's comments already warn about); `pkgs.devenv` (measured 2.3.1, no `machines` — bare `devenv` would disagree with `bin/devenv`, the exact trap the workstation lives with); `nix profile install` / another gcroot (imperative — design D6's objection: missing whenever a script or another operator runs the command) |
| D3 | Module split | role content in a new `hosts/netcup/operator.nix`, imported from the role block in `devenv.nix` | inlining in `devenv.nix` (which stays the thin two-consumers file; long justification lives beside its module — the `tailnet.nix` / `self-deploy.nix` pattern); appending to `self-deploy.nix` (different concern: that file is deploy preconditions, this is user environment) |
| D4 | How `gh` authenticates | per-use `secretspec run --reason "…" -- gh …` once `GH_TOKEN` is declared: the value never enters the shell environment, the tree, the store, or the host's disk | `env.GH_TOKEN` in home-manager (leaks to every process, contradicts SecretSpec's runtime-loading best practice); a root-`0600` `~/.config/gh/hosts.yml` on a public VPS (at rest, and `deploy` cannot refresh bootstrap files — the §4.1 gap again); `install.secrets` (install-only, and gh is not an install-time need). Cost accepted: `require_reason = true` means every `secretspec run` carries `--reason` or `SECRETSPEC_REASON` |
| D5 | How the host learns the cache | `nix.settings.substituters` **and** `nix.settings.trusted-public-keys` += `devenv.cachix.org` (key `devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=`, the same one `bin/devenv` documents) in the system role | widening `trusted-users` (self-deploy D5 rejected it — a permanent privilege grant for a cache problem); per-invocation `--option extra-substituters` (measured silently dropped for untrusted users); touching nothing (non-root toolchain rebuild = Rust workspace compile, and the agent-runner premise fails) |
| D6 | `GH_TOKEN` now or when rate limits are proven | declare it **now** (operator decision, 2026-09-28), consume it only per use; the `nix.conf` delivery stays a non-goal | waiting for measurement (the declaration is what makes `secretspec run -- gh` work at all — supply before demand); putting it on the machines path changes nothing that is not already accepted for `TS_AUTH_KEY` |
| D7 | One change or two (tooling vs secret) | one change | splitting (gh without a resolvable credential is not "durable tooling" — the repo's graduation rule — and the manifest edit is one line either way) |
| D8 | `home.stateVersion` | `"26.11"` — enum-verified, symmetric with `system.stateVersion = "26.11"` | an older value (keeps pre-26.11 defaults for no reason on a fresh home) |
| D9 | How `~/projects` is created | an activation snippet (`lib.hm.dag.entryAfter ["writeBoundary"]`, `mkdir -p`) | `home.file."projects"` — that creates a **symlink into the read-only Nix store**, unusable as a working tree; relying on the operator to mkdir by hand (not declarative, not re-image proof) |

## Risks / Trade-offs

- **[R1] A home-manager activation failure leaves the system deploy applied, and
  no rollback reverts home-manager files.** → Accepted and made spec-visible:
  the `netcup-self-deploy` rollback requirement is MODIFIED to scope restoration
  to the system role. Mitigation: the first role is deliberately tiny (devenv,
  gh, one mkdir), the deploy order is reviewed before the first application, and
  `machines status` plus a post-deploy check covers the HM half explicitly.
- **[R2] The `home-manager` input floats on master until `devenv.lock` pins it,
  and master may not pair with devenv-nixpkgs rolling (HM's
  `home.enableNixpkgsReleaseCheck` defaults to `true` and warns on mismatch).**
  → Local eval-before-any-host-touch tasks; if eval warns or breaks: pin the
  input to the release branch that matches 26.11, or set
  `home.enableNixpkgsReleaseCheck = false` with the reason written down.
- **[R3] Adding `GH_TOKEN` makes it a prerequisite for every `machines`
  invocation — including the host's self-deploy loop, which resolves the profile
  under D3's at-rest credential.** → If that read-only credential cannot read
  the item, the self-deploy loop stops working. Check tasks run `machines info`
  on **both** machines before the change is called done; the vault is unchanged,
  so the failure mode is detection, not data.
- **[R4] D2 replicates an *internal* devenv function (`sourceInfo`/`narHash`
  contract), not a public API.** → A check task asserts
  `devenv --version` from the user profile equals `bin/devenv --version`; if the
  contract ever breaks, eval fails loudly rather than silently shipping 2.3.1.
  Fallback (documented here): add the third pin after all.
- **[R5] The substituter declaration is wrong-keyed or unreachable.** → The key
  is copied from `bin/devenv`'s own documented flags; local build-eval tasks run
  before deploy; rollback is a plain system rollback (the setting lives in the
  system role).
- **[R6] The activation driver's `runuser` may be absent on the host.** → The
  driver falls back to `sudo -H -u hbohlen`, and `security.sudo` with
  `wheelNeedsPassword = false` is already declared; a check task confirms which
  path the host takes before the first deploy is trusted.
- **[R7] `~/projects` already exists on the host** (created by hand). → The
  activation mkdir is idempotent; no `home.file` collision is possible under D9.
- **[Trade-off] The host now has `devenv` on `PATH` *and* `bin/devenv`.** Two
  names, one version — that is the point (they agree), but the workstation's
  "never bare `devenv`" rule must be restated as a *workstation-only* rule in
  the docs, or the next operator gets a contradictory instruction.

## Migration Plan

1. Local, no host contact: hand-add the `home-manager` input to `devenv.yaml`
   (comments preserved), write `hosts/netcup/operator.nix`, the `devenv.nix`
   role block, the `secretspec.toml` entry, the substituter settings; run the
   eval suite (`machines info`, `eval machines.netcup.build.nixos`,
   `eval …build.home-manager` if exposed / build task, `secretspec` resolution of
   `GH_TOKEN`).
2. Build both closures locally (`devenv build machines.netcup` and the HM
   output) — nothing on the host changes yet.
3. Deploy from the workstation over the existing root path (or via the host's
   self-deploy loop): system role applies first (one changed setting — the
   substituters), then home-manager activates as `hbohlen`.
4. Verify per the spec scenarios: versions on `PATH`, `gh` present,
   `secretspec run -- gh auth status`, `~/projects` exists, `machines status`
   succeeded, non-root substitution probe as `hbohlen`.
5. Rollback: `machines rollback netcup` restores the system role (substituters
  included). The home-manager half has **no** rollback — undo by editing the
  role block and deploying again, which is why the first role is minimal.

## Open Questions

1. Does the locked home-manager ref evaluate cleanly against devenv-nixpkgs
   `c2f38fe7` (R2)? First eval answers this; the fix is a pin or a disabled
   release check, decided then.
2. Should `bin/devenv` derive its build URL from `devenv.lock` (single source of
   truth for both pins)? Deferred as a non-goal; worth a hygiene change later.
3. Does `machines info` render the roles as a list or a set — i.e. does the
   `netcup-machine` enumerable scenario need the MODIFIED delta this proposal
   anticipates? Resolved by running `machines info` after the input lands; if
   the output still reads `role nixos` only, the delta is dropped before
   archive.
4. When `~/projects` gains its first project, does it get its own
   `secretspec.toml` (and thus its own profile-resolution cost)? Out of scope
   here; recorded so the cost is chosen, not inherited.
