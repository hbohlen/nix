# Proposal: extract-netcup-config-module

## Why

The netcup literals are copy-pasted across the tree: `152.53.92.126`,
`/home/hbohlen/nix`, `/home/hbohlen/.ssh/id_ed25519-op-dev`,
`/var/lib/tailscale/authkey`, node `nc`, `worm-hue.ts.net`, both public keys and
both fingerprints, `/dev/vda`, `26.11`, and `devenv.cachix.org-1:…` all appear in
`devenv.nix`, `hosts/netcup/*`, `secretspec.toml`, ~9 `scripts/*.sh`, and
`openspec/config.yaml`. The handoff (§10) names this as the cost the next
access-policy change pays — it would edit the same address in ~9 files. This
change advances the **consolidation-before-hardening milestone**: make the
literals and this repo's hard invariants one declared surface, and install the
profile seam a fleet will need, *before* anything changes access policy or adds a
second host.

devenv 2.4 provides both mechanisms. `extending` defines an `options`/`config`
module with `lib.mkOption`/`lib.mkIf`, consumed through `devenv.yaml`
`inputs`/`imports`, so values and eval-time assertions live in one place;
`profiles` gives a deterministic selection seam (base < hostname < user <
`--profile`) and `devenv --profile … machines deploy` a fleet selector. Sources:
<https://devenv.sh/extending/>, <https://devenv.sh/profiles/>,
<https://devenv.sh/inputs/>, <https://devenv.sh/machines/>.

## What Changes

- **A repo-local devenv config module** (`options` + `config`,
  `lib.mkOption`/`lib.mkIf`), consumed through `devenv.yaml` `inputs`/`imports`,
  that owns the netcup literals listed above and exposes them as options
  (`netcup.*`) so `devenv.nix`, `hosts/netcup/*`, and the scripts derive from one
  declaration instead of restating it.
- **The repo's hard invariants become module defaults and assertions**, so drift
  fails eval rather than being rediscovered in a script: root SSH is required for
  install/deploy (`target.host` must be `root@…`); secret source paths must be
  **strings** (`"secrets/…"`), never Nix path literals that copy into the store;
  a Machine module must not set `nixpkgs.config` (that policy belongs in
  `devenv.yaml`); and no secret literal may appear in a module.
- **Profiles for the workstation/host split.** The workstation half of
  `devenv.nix` — documented as deliberately empty for this milestone — becomes a
  named profile, so tooling graduates into a profile instead of accumulating in
  the one file. A `profiles.hostname."<host>"` profile is the seam the future
  `oci` host uses rather than a second Machine declaration.
- **`devenv --profile … machines deploy` as the fleet selector**, giving a
  documented per-environment/per-host deploy seam.
- **BREAKING (declaration shape):** the canonical literals and the invariant
  statements move out of `devenv.nix`/`hosts/netcup/*`. Anything that reads a
  literal from a specific file — the preflight scripts' hardcoded `TARGET`,
  `SSHOPT_PATH`, `AUTHKEY_PATH`, `NODE`, `TAILNET_SUFFIX` and fingerprints — must
  take it from the module (evaluated) instead. `machines info` (name, system,
  role) and the evaluated `nixos-system-netcup-*` are unchanged.

Non-goals, stated explicitly:

- **No change to runtime posture or access policy.** No hardening, no closing
  root login, no tailnet-only SSH, no firewall/sshd change, no re-image. The
  root-SSH invariant is *encoded*, not altered.
- **No second host.** `oci` is not declared; only the `profiles.hostname` seam is
  installed for it.
- **The other devenv opportunities are separate changes and are not bundled:**
  `tasks.*` migration (item 4), `enterTest` suites (5), `machines check`/`plan`
  (6/7), `deploy.healthCheck` (1), `require_version` (2), `copyHostKeys` (8),
  `allow_unfree` relocation (3), `outputs`/`eval`/`repl` plumbing (11/12).
- **No `disabledModules`** replacement of devenv built-ins.
- **No SecretSpec change:** no secret is added, created, or rotated; every
  `devenv machines` invocation still resolves the whole profile on both machines.
- **The planning root stays on the workstation.** Specs, wiki and authored changes
  do not move.

## Capabilities

### New Capabilities

- `netcup-config-module`: the repo-local devenv config module and its profile
  layout — the option surface that centralizes the netcup literals, the
  defaults/assertions that encode this repo's hard invariants at eval, and the
  workstation/host/`hostname` profile split with `devenv --profile … machines
  deploy` as the fleet selector.

### Modified Capabilities

- `netcup-machine`: the "declared as a devenv Machine" requirement is restated.
  Today it names `devenv.nix` as the declaration and the sole surface; after this
  change the Machine's literals and invariants are supplied by the shared config
  module consumed through `devenv.yaml` `imports`, so the declaration surface is
  the `devenv.nix` entry point **plus** that module — still with no `flake.nix`
  host and no host-assembly function. The machine name, system, role and
  evaluated system are unchanged, so only the declaration's source and the
  invariant-enforcement clause change.

## Impact

- **Files:** `devenv.nix` (consume the module), `devenv.yaml` (a hand-added
  `imports:`/`inputs:` entry — `devenv inputs add` rewrites this file and **drops
  every comment**, so the edit is manual), a new module path (the design decides
  where), `hosts/netcup/*` (derive the literals), the `scripts/*.sh` that
  hardcode `TARGET`/`SSHOPT_PATH`/`AUTHKEY_PATH`/`NODE`/`TAILNET_SUFFIX`/
  fingerprints, `openspec/config.yaml` (de-duplicate the facts the module now
  owns), and `docs/devenv-feature-opportunities.md` (items 9 and 10 closure at
  archive).
- **Eval:** `devenv machines info` and `devenv eval machines.netcup.*` stay
  observably the same; the new assertions can now fail eval on drift (intended).
  No host is contacted and nothing is written to the host by this change itself.
- **Both machines:** no new at-rest secret; the profile-resolution cost is
  unchanged (no secret added).
- **Reference honesty (`~/projects/nixos`, a REFERENCE, never copied):** this
  change **drops** the previous repo's host-assembly model — `lib/mkHost.nix` and
  its shared `modules/nixos/` NixOS module collection — as the pattern for this
  host: `netcup-machine` already forbids a competing host-assembly surface, and
  the extraction here is a devenv config module (`options`/`config`), not a
  `nixosSystem` assembler. It **contradicts ADR-0006** ("declare `machines.netcup`
  … importing `hosts/netcup/default.nix` and `modules/nixos` unchanged", beside a
  flake host): this repo has no flake host, does not import a shared
  `modules/nixos`, and that ADR was measured against a different, Debian netcup
  at `100.95.92.47`. Nothing from `~/projects/nixos` is inherited by copying.
