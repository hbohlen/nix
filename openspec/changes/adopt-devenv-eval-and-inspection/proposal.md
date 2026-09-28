# Proposal: adopt-devenv-eval-and-inspection

## Why

This repository inspects its own Machine through hand-rolled plumbing.
`scripts/self-deploy-preflight.sh` defines an `evalattr()` helper that wraps
`devenv eval` in an inline `python3 -c` just to unwrap one attribute,
`scripts/tailnet-preflight.sh` repeats the same `devenv eval | python3`
extraction, and `scripts/self-deploy-run.sh` — which runs on the host — greps
the evaluated JSON for a `nixos-system-netcup` store path because the host
deliberately ships no interpreter. devenv 2.4 already provides the surface these
wrappers imitate: `devenv eval <attr…>` returns JSON keyed by attribute,
`devenv info` (alias `show`) prints locked inputs/env/scripts/processes/packages,
`devenv repl` exposes `inputs` beside `devenv` and `pkgs`, and
`devenv build machines.<name>.build.<role>` builds one role instead of the whole
Machine. Adopting that surface removes the per-script eval shrapnel and lets the
preflight build the nixos role alone.

**Milestone advanced:** the current post-install milestone — the host runs its
declared NixOS, with tailnet, self-deploy and operator environment — along its
operational-consolidation edge: the declaration is inspected with devenv's own
commands rather than per-script eval shrapnel and a second language runtime. It
is also a prerequisite in spirit for `model-netcup-operations-as-tasks`: the task
graph that will re-home these operations is written once, against devenv's
inspection surface, instead of porting the shell wrappers first.

**Non-goals, stated explicitly:**

- **No host touch.** No `install`, no `deploy`, no reboot, no firewall/SSH/secret
  change, no re-image; every step in scope is eval- or inspection-only and can
  run on the workstation. No new secret and no new vault item — the SecretSpec
  profile is unchanged.
- **No spec-level behavior change.** The same evidence, the same gates and the
  same commands of record are produced; only the plumbing that produces them
  changes. This is implementation ergonomics, so no capability spec is created or
  modified (see **Capabilities**).
- **Not the tasks migration (item 4), the tests suite (item 5), `machines
  check`/`plan` (items 6/7), `deploy.healthCheck` (1), `require_version` (2),
  `install.copyHostKeys` (8), the central config module or profiles (9/10), or the
  deferred set (14).** Each is a separate change
  (`model-netcup-operations-as-tasks`, `adopt-machines-check-and-plan`,
  `pin-devenv-toolchain-version`, `extract-netcup-config-module`,
  `record-deferred-devenv-mechanisms`).
- **Not item 12.** `devenv tasks list --json`, agent quiet mode and traces belong
  to the tasks migration; this change takes item 11 only.
- **Does not remove the loop's record.** `machines status` / `machines rollback`,
  the loopback target override, the on-host deploy and the firewall-facts read
  remain; this change does not replace the access gate (that is
  `adopt-machines-check-and-plan`).
- **Does not change the evaluated system.** `netcup-machine`'s
  `devenv eval machines.netcup.build.nixos` and `netcup-self-deploy`'s
  no-remote-builder and pinned-toolchain requirements still hold, because the
  evaluated system is unchanged.

## What Changes

- **`devenv eval <attr…>` replaces the eval wrapper.** `evalattr()` in
  `scripts/self-deploy-preflight.sh` — `devenv eval "$1" | python3 -c …` — is
  removed; the script asks `devenv eval` for the attributes it needs and reads the
  JSON keyed by attribute. The same inline `devenv eval | python3` extraction of
  `machines.netcup.build.nixos` in `scripts/tailnet-preflight.sh` step 7 is
  replaced, and `scripts/self-deploy-run.sh`'s host-side
  `devenv eval … | grep -oE '/nix/store/…-nixos-system-netcup…'` — the grep that
  exists only because the host has no `python3` — is re-expressed against the same
  surface, so no second interpreter is required on either machine.
- **`devenv info` (alias `show`) becomes the readable inspection command.**
  Locked inputs, environment, scripts, processes and packages are read from
  devenv rather than from a hand-rolled eval-and-parse pipeline; `devenv repl`
  becomes the interactive one, whose `inputs` binding (added in 2.2) sits beside
  `devenv` and `pkgs`. These are added affordances for the operator and the coming
  task graph; no existing script depended on them.
- **Role-scoped build.** `scripts/self-deploy-preflight.sh`, `scripts/preflight.sh`
  and `scripts/tailnet-preflight.sh` change `devenv build machines.netcup` to
  `devenv build machines.netcup.build.nixos`, building only the nixos role the
  preflight and the deploy actually use. For this single-role Machine the
  resulting system is identical; the change is a deliberate narrowing, not a
  behavior change today.
- **The JSON workarounds in the verify scripts are consolidated.**
  `scripts/self-deploy-verify.sh` and `scripts/operator-env-verify.sh` currently
  parse devenv output with inline `python3` while the interpreter-less host
  greps — two workarounds for the same devenv output. They are rewritten to
  consume devenv's own structured output (`devenv eval`, and the `machines`
  subcommands' JSON) instead of carrying a per-script interpreter.
- **Sources:** <https://devenv.sh/getting-started/> ·
  <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>
  (REPL `inputs`) · <https://devenv.sh/machines/> (role-scoped build).

### Relationship to `model-netcup-operations-as-tasks`

This change is proposed to land **before** the tasks migration. The migration
retires the fourteen `scripts/*.sh` and re-expresses their procedures as tasks;
if the inspection surface is settled first, the graph is written once against
`devenv eval`/`info`/`repl` and the role-scoped build, rather than porting the
bash wrappers and then rewriting them. The ordering is not a hard dependency,
though: the two changes overlap at exactly one point, the `evalattr` helper (and
the per-script eval/parse steps around it), and **whichever lands second
reconciles that overlap**. If the tasks migration lands first, this change
applies the same adoption to the task graph and removes whatever `evalattr`
residue remains; if this change lands first, it replaces `evalattr` with
`devenv eval` and the migration then retires the scripts wholesale. Until the
migration lands, the script paths and their caller-visible commands are
unchanged.

### Scope boundary with `extract-netcup-config-module`

`extract-netcup-config-module`'s non-goals name "eval/repl plumbing (11/12)" and
exclude it from that change. This change **owns item 11** of
`docs/devenv-feature-opportunities.md`; item 12 stays with the tasks migration.
If the config module lands first, it may centralize the literals this change's
scripts still read as constants, and this change then reads them through
`devenv eval` — the same surface, not a competing one.

### Not inherited from `~/projects/nixos`

The prior implementation carries no `evalattr`, no per-script
`devenv eval | python3` extraction and no host-side grep of the evaluated system;
its only eval reference is a `devenv.nix` comment that `devenv eval` still
evaluates on an older binary. So this change **drops and contradicts nothing**
there — the plumbing being replaced is this repository's own, and no decision from
the reference is copied. It does depart from that repo's ambient-toolchain
assumption (it carries no `bin/devenv`), which `pin-devenv-toolchain-version`
already addresses; that departure is stated, not inherited.

## Capabilities

### New Capabilities

None. This is adoption of devenv's own inspection surface, not a new spec-level
behavior, so no `specs/<name>/spec.md` is introduced.

### Modified Capabilities

None. No requirement in `netcup-disk-layout`, `netcup-install`, `netcup-machine`,
`netcup-operations`, `netcup-self-deploy` or `netcup-tailnet` changes: the
evidence, the gates and the evaluated system are identical.
`netcup-operations`'s scenario naming `devenv eval machines.netcup.deploy.facts`
still holds because `devenv eval` is retained, and `netcup-machine`'s
`devenv eval machines.netcup.build.nixos` requirement is untouched. The
capabilities introduced by open changes (`netcup-operator-env`,
`netcup-task-graph`, `netcup-config-module`) are also untouched. Listing none is
deliberate, not an omission.

## Impact

- **Files:** `scripts/self-deploy-preflight.sh` (remove `evalattr`; role-scoped
  build), `scripts/tailnet-preflight.sh` (inline eval extraction; role-scoped
  build), `scripts/self-deploy-run.sh` (replace the host-side grep),
  `scripts/self-deploy-verify.sh` and `scripts/operator-env-verify.sh`
  (consolidate JSON parsing), `scripts/preflight.sh` (role-scoped build), and
  `docs/devenv-feature-opportunities.md` (item 11 closure at archive). If
  `model-netcup-operations-as-tasks` lands first, the same edits land in the task
  graph instead of the scripts.
- **Workstation:** still requires the pinned `bin/devenv` 2.4.0; gains `devenv
  info`/`show` and `devenv repl` as inspection commands, and the eval paths stop
  depending on a `python3` on the invoking side. No new dependency is added.
- **Host:** no NixOS change; unaffected until its next deploy. The on-host loop
  uses the same `devenv eval` surface, removing the grep that existed only
  because the host has no `python3`.
- **Specs:** none created or modified; `openspec validate` on the six existing
  specs is unaffected, and no delta spec is required.
- **Vault / secrets:** unchanged. Every `devenv machines` invocation still
  resolves the whole SecretSpec profile, and `devenv eval` resolves it as before;
  no item is added, moved or rotated.
- **BREAKING:** none. The script paths, their caller-visible commands and the
  commands the capability specs name are all retained; `devenv build
  machines.netcup.build.nixos` produces the same system as the all-roles build for
  this single-role Machine.
