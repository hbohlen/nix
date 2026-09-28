# Proposal: model-netcup-operations-as-tasks

## Why

This repository's operational knowledge lives in fourteen hand-rolled shell
scripts (`scripts/*.sh`). Each one re-implements the same boilerplate — the SSH
option array, `step()/note()/check()`, the bundled-`secretspec` lookup,
`SECRETSPEC_REASON`, the `op-sa-token` backfill, the `machines status` JSON
parsing, the firewall-facts assertion, `loop.json` validation, reboot wait
loops, fingerprint constants — and the ordering that actually matters
("preflight must pass before anything touches the host", an OpenSpec rule in
`openspec/config.yaml`) is encoded in shell call order and prose comments rather
than declared. devenv 2.4 supplies the missing mechanism: `tasks.*`,
`enterTest`, and `devenv tasks list --json`. The host, tailnet, self-deploy and
operator-env machinery has now proven durable, which is this repo's stated bar
for tooling graduating into the declaration.

**Milestone advanced:** every operational procedure this repository runs —
preflight gates, deploys, and read-only verification — is declared in
`devenv.nix` as a devenv task graph and exercised by `devenv test`, so the
ordering, the gates and the parser live in the declaration instead of in shell.

**Non-goals, stated explicitly:**

- **The live host is untouched.** No `install`, no `deploy`, no reboot, no new
  firewall/SSH/secret value. This change adds no host-side NixOS configuration;
  it is delivered by editing the repository (any later `deploy` would carry no
  host change from it). Nothing here runs against netcup.
- **The watchability guarantee is not weakened.** Host-touching steps stay
  behind an explicit eval-or-check gate and remain operator-visible
  (`netcup-operations`); `enterTest` covers only checks that do not contact the
  host.
- **The other `devenv-feature-opportunities` items are out of scope**, and each
  is another change: `deploy.healthCheck` (#1), `require_version` (#2), nested
  `allow_unfree` (#3), `machines check` (#6), `machines plan`/`apply` (#7),
  `install.copyHostKeys` (#8), the central config module (#9), profiles (#10),
  `devenv eval/info/repl` (#11), `processes` vs systemd for the agent runner
  (#13), and the conditional set (#14). Items #6/#7 already have a separate
  change directory reserved.
- **The planning root does not move** and **no agent-runner service model** is
  chosen (handoff ledger #10): tasks are not processes, and this change does not
  decide `devenv processes` vs NixOS services.
- **`netcup-disk-layout`, `netcup-install`, `netcup-machine` and
  `netcup-tailnet` behavior is unchanged.** Their requirements are still
  satisfied by tasks; no port, layout, image or node changes.
- **No new secret and no new vault item.** The SecretSpec profile is unchanged.

## What Changes

- **BREAKING — the script command surface is retired.** `scripts/preflight.sh`,
  `scripts/postinstall-verify.sh`, `scripts/reboot-check.sh`,
  `scripts/tailnet-{preflight,verify,enroll,reboot-check}.sh`,
  `scripts/operator-env-verify.sh`,
  `scripts/self-deploy-{preflight,verify,drift,run,host}.sh` and
  `scripts/bb-pane-run.sh` are replaced by declared tasks. Any doc, skill or
  habit that invokes `./scripts/…sh` by path breaks; the entry point becomes
  `devenv tasks run <ns>`.
- **New: the operational DAG is declared as `tasks."<ns>:<name>"`** with `exec`,
  `before`/`after` edges and dependency states (`@started`/`@ready`/
  `@succeeded`/`@completed`), `wantedBy`, `execIfModified`, and `status`
  (skip + cached outputs) so the expensive build/deploy steps re-run only when
  their inputs changed. `input`/outputs flow through the documented
  `DEVENV_TASK_*` variables. The DAG is run with `devenv tasks run <ns>` and
  `--mode single|before|after|all`.
- **The existing "eval-or-check before anything host-touching" rule becomes an
  edge, not a convention.** A gate task (`@succeeded`) precedes every task that
  writes to, reboots or enrols the host; a task that only touches the host is
  never reachable from `enterTest`.
- **New: the read-only verification suites become `enterTest` / `devenv test`
  content** (`devenv test` is an alias for the graph run in `all` mode).
  `.test.sh` is auto-detected, `wait_for_port` is used for readiness, and
  `config.devenv.isTesting` branches config. The `--help`/version assertions and
  the eval-only firewall-facts/`loop.json` checks move here; the host-touching
  suites (tailnet, operator-env, reboot) stay explicit tasks behind their gate.
- **New: `devenv tasks list --json` is the machine-readable graph** for agent
  and CI automation. devenv's automatic quiet mode on coding-agent detection
  (`CLAUDECODE`, `OPENCODE_CLIENT`, `AI_AGENT`; opt out with
  `DEVENV_NO_AI_AGENT=1`) and `--trace-to` span traces replace most of the
  blanket `--no-tui`, which the scripts pass today to keep a pane readable.
- **Modified: `netcup-operations`** — its requirements keep their force, but the
  command surface they describe changes from `scripts/*.sh` to tasks (for
  example the *A verification script runs in a pane* scenario becomes a
  verification *task*). The wrapper's environment duties (vault token,
  `SECRETSPEC_REASON`, no secret value in scrollback, the on-disk record of what
  a pane was asked to run) are retained.
- **Sources:** <https://devenv.sh/tasks/> · <https://devenv.sh/tests/> ·
  <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>
  · <https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/>.
- **Dropped / contradicted relative to `~/projects/nixos`:** nothing is dropped
  from that repo's *decisions* — it declares no task graph (a search for
  `tasks."`/`devenv tasks` finds none), so there is no mechanism to inherit. It
  **contradicts that repo's operational posture**, deliberately and narrowly: the
  reference runs shell entry points (`scripts/netcup-repo`,
  `deploy/netcup-install.sh`) with a placeholder `enterTest` ("test: shell
  alive") and a single `.test.sh` that contacts no host. This change declines to
  copy that style. The `enterTest`/`.test.sh` *mechanism* is re-earned for this
  repo's real read-only suites (one derivable from ADR-0001's devenv-first
  posture), not inherited; its scripts, `enterTest` body and test file are not
  copied.

## Capabilities

### New Capabilities

- `netcup-task-graph`: the repository's operational procedures are declared as
  one devenv task graph — namespaced tasks with dependency edges and dependency
  states, the eval-or-check gate before every host-touching task, `enterTest` /
  `devenv test` for the read-only suites, and `devenv tasks list --json` plus
  quiet/agent detection as the machine-readable surface for agents and CI.

### Modified Capabilities

- `netcup-operations`: the watchability and wrapper requirements keep their
  force, but the command surface they describe moves from `scripts/*.sh` to
  tasks. The scenario *A verification script runs in a pane* is restated for a
  verification task; the scenarios that speak of "any script in `scripts/`" are
  reworded to the task graph. The pane-environment requirement (vault token,
  `SECRETSPEC_REASON`, presence-never-value) and the on-disk record requirement
  are retained unchanged.

No other capability's requirements change: `netcup-self-deploy`'s
"documented and re-readable" requirement still holds because the procedure
document will name tasks as its verifying commands, and its loopback deploy and
rollback requirements are untouched; `netcup-install`, `netcup-tailnet`,
`netcup-machine` and `netcup-disk-layout` reference no script by name and keep
their behavior. This change intends to list them as **not** modified, so the
choice is reviewable.

## Impact

- **Files:** `devenv.nix` gains `tasks.*` and `enterTest` (whether the task
  declarations live in `devenv.nix` or a sibling module is a design decision);
  the fourteen `scripts/*.sh` files are removed. The procedure documents
  (`docs/install-netcup.md`, `docs/self-deploy-netcup.md`,
  `docs/tailnet-netcup.md`, `docs/handoff-followups.md`) are rewritten to name
  `devenv tasks run …` / `devenv test` instead of script paths. The capability
  spec `netcup-task-graph` and the `netcup-operations` delta land under
  `openspec/specs/` when this change is archived.
- **Workstation:** requires the already-pinned `bin/devenv` 2.4.0; `devenv
  tasks` / `devenv test` become the operational entry points. `--no-tui` is
  largely replaced by agent auto-detection and `--trace-to`.
- **Host:** no NixOS change. The one touchpoint is the self-deploy loop, whose
  host-side entry (`scripts/self-deploy-run.sh` today) must be re-expressed as a
  task run at the checkout — the host pulls the declaration before it can run it,
  and the `netcup-self-deploy` requirement that the host rebuild itself stays
  satisfied. This ordering is a design concern, named here so it is not
  discovered mid-implementation.
- **Agents and CI:** `devenv tasks list --json` and trace output become the
  structured handles that replace ANSI scraping; `bb-pane-run.sh`'s env-backfill
  and output-capture duties move into the graph.
- **Vault / secrets:** unchanged — the same profile resolves, no item is added,
  moved or rotated.
- **Reference honesty:** nothing in `~/projects/nixos` is inherited by copying;
  its ADRs (0001 devenv-first, 0006 machines) do not decide this, and its shell
  operations and placeholder `enterTest` are declined in favor of re-earning the
  mechanism for this repo's suites.
