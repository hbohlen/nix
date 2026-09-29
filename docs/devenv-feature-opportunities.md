# devenv feature opportunities for this config

Written 2026-09-28. This is a **research note**, not a change proposal: it maps the
devenv features in the 2.1–2.4 releases and the current docs onto the actual shape
of `~/nix`, and lists where a devenv feature could replace hand-rolled machinery.

Method: the pages below were read as primary sources (fetched 2026-09-28); the
repo was inventoried from `devenv.nix`, `devenv.yaml`, `secretspec.toml`,
`hosts/netcup/*`, all 14 `scripts/*.sh`, `bin/devenv`, `docs/*`, and `openspec/*`.
Every claim carries the source that owns it. Where a claim came from the devenv
YAML JSON Schema rather than prose, the schema is cited and the raw keys are
quoted.

**Sources (primary):**

- Blog 2.1 — <https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/>
- Blog 2.2 — <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>
- Blog 2.3 — <https://devenv.sh/blog/2026/09/07/devenv-23-portless-and-tui-configuration/>
- Blog 2.4 — <https://devenv.sh/blog/2026/09/24/devenv-24-machines/>
- Machines — <https://devenv.sh/machines/>
- Processes — <https://devenv.sh/processes/>
- Tasks — <https://devenv.sh/tasks/>
- Tests — <https://devenv.sh/tests/>
- Profiles — <https://devenv.sh/profiles/>
- Extending — <https://devenv.sh/extending/>
- Outputs — <https://devenv.sh/outputs/>
- Pinning — <https://devenv.sh/pinning/>
- Inputs — <https://devenv.sh/inputs/>
- Ad-hoc environments (`-O/--option`) — <https://devenv.sh/ad-hoc-developer-environments/>
- Auto-activation / trust — <https://devenv.sh/auto-activation/>
- TUI customization — <https://devenv.sh/tui-customization/>
- YAML options — <https://devenv.sh/reference/yaml-options/>
- Options reference — <https://devenv.sh/reference/options/>
- SecretSpec integration — <https://devenv.sh/integrations/secretspec/>
- GitHub Actions — <https://devenv.sh/integrations/github-actions/>
- YAML JSON Schema (the pinned CLI's editor schema) — <https://devenv.sh/devenv.schema.json>
- CLI subcommands (no docs page exists) — <https://github.com/cachix/devenv/blob/main/devenv/src/cli.rs>

---

## Part 1 — The improvement list

Ranked roughly by payoff. "Where" points at the current code; "Feature" is the
devenv mechanism; "Source" is the owning primary page.

### 1. Set `machines.netcup.deploy.healthCheck`, so a bad deploy rolls back itself

- **Where:** `devenv.nix:15–111` — the Machine block declares `install.secrets`
  but **no `deploy` block at all**. Deploy therefore uses the documented default
  health check (`"true"`), which "checks only the system paths"
  (blog 2.4; options reference). The real post-deploy acceptance logic lives in
  `scripts/operator-env-verify.sh`, `scripts/self-deploy-verify.sh`, and
  `scripts/postinstall-verify.sh`, run by hand after the fact.
- **Feature:** `machines.<name>.deploy.healthCheck` (string, default `"true"`) plus
  `machines.<name>.deploy.rollbackTimeout` (int 30–600, default `300`). A
  target-side watchdog restores the previous system if activation or the health
  check fails, or if the controller cannot confirm before the deadline.
- **Payoff:** the system role's rollback stops being a *manual* discovery in a
  verify script and becomes part of the deploy transaction. This is the closest
  declarative answer to the documented risk that home-manager has **no rollback**
  and a failed HM activation leaves the system generation active
  (`hosts/netcup/operator.nix`; design R1).
- **Caveats:** runs as root on the target with absolute paths; must allow time
  for service startup and SSH reconnection. HM is a second activation that NixOS
  rollback does **not** revert (machines page).
- **Source:** <https://devenv.sh/machines/> · <https://devenv.sh/blog/2026/09/24/devenv-24-machines/>
  · <https://devenv.sh/reference/options/#machines>

### 2. Add `require_version` — turn the "use `bin/devenv`, never bare `devenv`" rule into an error

- **Where:** `devenv.yaml` has no `require_version` key. The rule is carried only
  in prose: `bin/devenv:1–39`, `devenv.nix:9–13`, and
  `docs/handoff-followups.md` §6 ("bare `devenv` on this workstation is 2.2.2 and
  has no `machines` subcommand"). A wrong binary currently fails late and
  confusingly.
- **Feature:** `require_version` — "Set to `true` to enforce that the CLI version
  matches the modules version (from the `devenv` input), or use a constraint
  string" (schema; added 2.1).
- **Payoff:** `require_version: true` is exactly this repo's invariant — `bin/devenv`
  is `v2.4.0` and the `devenv:` input is `v2.4.0` (`devenv.yaml:57–59`). A bare
  2.2.2 `devenv` then fails with a clear version error instead of
  "Failed to get attribute 'devenv.config.machinesMeta'".
- **Source:** <https://devenv.sh/reference/yaml-options/> ·
  <https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/>

### 3. Move `allow_unfree` under `nixpkgs` (top-level key is deprecated)

- **Where:** `devenv.yaml:40` sets top-level `allow_unfree: true`.
- **Feature:** the pinned CLI's own schema marks top-level `allow_unfree` as
  `{"type":"boolean","deprecated":true}`, while `$defs/Nixpkgs.allow_unfree`
  exists and is documented as "Allow unfree packages. Default: `false`. Added in
  1.7." The current non-deprecated spelling is nested.
- **Payoff:** removes a latent warning/removal hazard on a key that gates the
  host's `pkgs._1password-cli` (`hosts/netcup/self-deploy.nix`), which the file's
  own comment says is mandatory for SecretSpec's 1Password provider.
- **Caveat:** confirm against the pinned 2.4.0 before flipping; the top-level form
  is presumably still functional, only deprecated. Either way, keep the
  reasoning comment.
- **Source:** <https://devenv.sh/devenv.schema.json> (verified 2026-09-28) ·
  <https://devenv.sh/reference/yaml-options/>

### 4. Model the preflight → deploy → verify chain as `tasks.*`, not 14 shell scripts

- **Where:** `scripts/*.sh` — every script re-implements the same boilerplate
  (`KEY`, `TARGET`, `SSHOPTS`, `step()/note()/check()`, the bundled `secretspec`
  lookup, `op-sa-token` backfill, `SECRETSPEC_REASON`, `machines status` JSON
  parsing, the firewall-facts assertion, `loop.json` validation, reboot wait
  loops, fingerprint constants). The ordering is encoded in shell call order and
  comments (`preflight.sh` ends by printing the *next* command;
  `self-deploy-host.sh` chains three scripts).
- **Feature:** `tasks.<name>` with `exec`, `before`/`after`, dependency states
  (`@started` / `@ready` / `@succeeded` / `@completed`), `wantedBy`,
  `execIfModified`, `status` (skip + cache outputs), `input`/`outputs`, `env`,
  `cwd`, `package`, and `devenv tasks run <ns>`. Processes are tasks too, with
  the `devenv:processes:` prefix. `devenv tasks run` schedules a subgraph via
  `--mode {single,before,after,all}`.
- **Payoff:** the DAG is declared once, helpers live in one place, and
  "preflight must pass before anything touches the host" (an OpenSpec rule in
  `openspec/config.yaml:108–112`) becomes an `after`/`before` edge rather than a
  convention. `status`/`execIfModified` make the expensive parts re-run only when
  inputs changed.
- **Source:** <https://devenv.sh/tasks/>

### 5. Move the read-only verification suites into `enterTest` / `devenv test`

- **Where:** `scripts/postinstall-verify.sh`, `scripts/tailnet-verify.sh`,
  `scripts/operator-env-verify.sh`, `scripts/self-deploy-verify.sh`,
  `scripts/self-deploy-drift.sh --fast-forwardable`, and the `--help`/version
  assertions are read-only evidence runners invoked manually.
- **Feature:** `enterTest` runs on `devenv test` (alias `ci`); processes are
  started/stopped for you; `devenv test` runs the task graph in `all` mode, so
  downstream setup tasks run; `wait_for_port <port> <timeout>` is provided; a
  `.test.sh` file is auto-detected; `config.devenv.isTesting` lets config branch.
- **Payoff:** one command produces the evidence the docs currently serialize by
  hand, and `--no-tui` preserves output in CI (blog 2.3). Note the docs' own
  advice: for complex setups with dependencies, prefer tasks hooked to
  `devenv:enterTest` — which is item 4 again.
- **Caveat:** the suites touch the live host; keep host-touching steps as explicit
  tasks and let `enterTest` cover eval-only checks.
- **Source:** <https://devenv.sh/tests/> · <https://devenv.sh/tasks/#entershell--entertest>

### 6. Use `machines check` as the access-change gate

- **Where:** `scripts/self-deploy-preflight.sh` re-derives firewall facts and root
  key presence by hand (step 9), and `scripts/tailnet-preflight.sh` does the same
  (step 8); the root-login/sudo posture is reasoned about in
  `docs/handoff-followups.md` §3 and `openspec/config.yaml:61–67`.
- **Feature:** `devenv machines check <name>` "compares declared SSH access
  changes with facts read from the target without building or deploying" and
  **blocks** deployments that would disable SSH or root login, warning about SSH
  port / admin-key changes. `check --json` is structured.
- **Payoff:** the one thing this repo most fears — a config that quietly closes
  the path it deploys over — becomes a first-class check instead of a bespoke
  assertion.
- **Caveats per the page:** it cannot verify external firewalls, dynamic keys, or
  that you possess a working key. Those stay custom.
- **Source:** <https://devenv.sh/machines/>

### 7. Insert `machines plan` → review → `apply` into the self-deploy loop

- **Where:** `scripts/self-deploy-run.sh` runs `devenv machines deploy netcup
  -O machines.netcup.target.host:string root@localhost --no-tui --yes` in one
  shot, then reads `machines status` back.
- **Feature:** `devenv machines plan <name>` builds and records the system, access
  facts, and closure deltas **without** copying/activating; a saved plan under
  `.devenv/machine-plans/<id>/` can be reviewed and then `devenv machines apply
  plan-…`, which refuses a stale plan. `plan --json` exports a portable plan.
- **Payoff:** matches this repo's whole doctrine — "nothing touches the live host
  without a prior eval-or-check" — and gives the operator the closure/access
  review before activation instead of after. `apply` also prepares all targets
  before activating any, which matters when `oci` lands.
- **Caveats:** a plan is a trusted deployment input (it selects executable store
  paths); a changed target or generation makes it stale.
- **Source:** <https://devenv.sh/machines/> · <https://devenv.sh/blog/2026/09/24/devenv-24-machines/>

### 8. `install.copyHostKeys` — stop treating host-key survival as a manual worry

- **Where:** `scripts/reboot-check.sh` records and re-asserts the SSH host key
  across a reboot; the install traps note "Host key verification failed" when
  local files are sent, and `scripts/self-deploy-*` reason about `known_hosts`.
- **Feature:** `machines.<name>.install.copyHostKeys` (boolean, default `false`) —
  "copy `/etc/ssh/ssh_host_*` from the live installer into the installed system
  before reboot."
- **Payoff:** makes the host key a stable, declared property across install,
  removing a class of post-reboot SSH surprises.
- **Caveat:** this *changes* the deployed host keys; decide deliberately. The
  handoff notes record a UEFI-fallback boot detail, and host-key stability has
  operational value here.
- **Source:** <https://devenv.sh/reference/options/#machines> · <https://devenv.sh/machines/>

### 9. Centralize the hardcoded blast radius in a custom module (`extending`)

- **Where:** `152.53.92.126`, `/home/hbohlen/nix`,
  `/home/hbohlen/.ssh/id_ed25519-op-dev`, `/var/lib/tailscale/authkey`, node `nc`,
  `worm-hue.ts.net`, both public keys and both fingerprints, `/dev/vda`, `26.11`,
  and `devenv.cachix.org-1:…` are repeated across `devenv.nix`,
  `hosts/netcup/*`, `secretspec.toml`, ~9 scripts, and `openspec/config.yaml`
  (the handoff calls out this blast radius explicitly).
- **Feature:** `Extending devenv` — an `options` block with `lib.mkOption` and a
  `config` block with `lib.mkIf`, consumed via `inputs`/`imports`; plus
  `disabledModules` for module replacement.
- **Payoff:** one module owns the literals and the invariants (root SSH required,
  secrets are strings not path literals, no `nixpkgs.config` in a Machine
  module — `openspec/config.yaml:61–83`), so the `scripts/` copy-paste and the
  `openspec/config.yaml` duplication shrink together.
- **Source:** <https://devenv.sh/extending/> · <https://devenv.sh/inputs/>

### 10. Use `profiles` for the workstation/host split and for machine-specific values

- **Where:** `devenv.nix:1–13` says the workstation half is "deliberately empty
  for this milestone"; the only selector between the two consumers is which
  subcommand you run.
- **Feature:** `profiles.<name>.module`, `profiles.hostname."<host>"`,
  `profiles.user."<user>"`, `extends`, deterministic priorities (base < hostname
  < user < `--profile`), and `devenv --profile … machines deploy` for a fleet.
- **Payoff:** tooling can graduate into a named profile (e.g. `workstation`,
  `host-tools`) instead of accumulating in the one file, and the future `oci`
  host gets a `hostname` profile rather than a second Machine declaration. It also
  gives a documented selection seam for per-environment deploys.
- **Source:** <https://devenv.sh/profiles/> · <https://devenv.sh/machines/>

### 11. `devenv eval` / `devenv info` / `devenv repl` instead of bespoke eval plumbing

- **Where:** `scripts/self-deploy-preflight.sh` has its own `evalattr`; scripts
  parse `machines status` JSON with `python3` workarounds because the host has no
  Python; `scripts/self-deploy-run.sh` greps the evaluated system for a
  `nixos-system-netcup` store path.
- **Feature:** `devenv eval <attr…>` returns JSON; `devenv info` (alias `show`)
  prints locked inputs/env/scripts/processes/packages; `devenv repl` exposes
  `inputs` alongside `devenv` and `pkgs`; `devenv build machines.<name>.build.nixos`
  builds a single role.
- **Payoff:** less per-script eval shrapnel, and role-scoped builds are already
  what `preflight.sh` wants (`devenv build machines.netcup` currently builds all
  roles).
- **Source:** <https://devenv.sh/getting-started/> ·
  <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>
  · <https://devenv.sh/machines/>

### 12. `tasks list --json`, quiet mode, and traces for the agent/automation surface

- **Where:** agent-side work is wrapped through `scripts/bb-pane-run.sh`, which
  hand-rolls env backfill and output capture; scripts universally pass `--no-tui`.
- **Feature:** `devenv tasks list --json` (machine-readable graph); automatic
  quiet mode when a coding agent is detected (`CLAUDECODE`, `OPENCODE_CLIENT`,
  `AI_AGENT`; broadened via `detect-coding-agent`, opt out with
  `DEVENV_NO_AI_AGENT=1`); `--trace-to [format:]destination` with `devenv.caller`
  and `devenv.*` span attributes; `devenv mcp`.
- **Payoff:** agents get structured handles instead of ANSI scraping, and the
  self-deploy loop gets traces across the process boundary. `--no-tui` could
  become mostly redundant.
- **Source:** <https://devenv.sh/tasks/> ·
  <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>
  · <https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/>

### 13. Decide `processes` vs NixOS services for the "agent runner" question

- **Where:** `docs/handoff-followups.md` ledger #10 ("`devenv processes` vs
  always-on services") is open.
- **Feature / answer from the docs:** devenv's process manager is powerful
  (`devenv up -d`, attach, `wait`, readiness probes, restart policies, watchdog,
  socket activation), **but** a process lives for the duration of the run and the
  manager is session-scoped — `devenv tasks run` stops every process it started
  when the graph finishes. Boot-surviving jobs therefore still want NixOS
  `services.*` or lingered user units. The docs also state config changes are not
  picked up by an attach; restart with `devenv processes down && devenv up -d`.
- **Payoff:** closes the decision rather than leaving it ambiguous — use
  `processes` for interactive/dev-time helpers, not for the always-on agent.
- **Source:** <https://devenv.sh/processes/> · <https://devenv.sh/tasks/#processes-as-tasks>

### 14. Optional/conditional — revisit these only if their premise changes

- **`hardware.facter`:** `devenv.nix:68` sets `null` deliberately. The docs say
  install auto-saves `.machines/<name>/facter.json` on first run and that the
  report "must be committed to git" so others/CI can build without contacting the
  target. `machines.install` re-runs facter on a re-image; switching is the
  "change in kind" `devenv.nix:60–67` already names. **Source:**
  <https://devenv.sh/machines/>.
- **`install.secretspec.execution = "target"`:** the current design chooses local
  deliberately (`devenv.yaml:15–19`). Target execution is a documented alternative
  that sends "the declaration, not the secret or provider credentials," but the
  1Password provider would have to work from the kexec'd installer. **Source:**
  <https://devenv.sh/machines/>.
- **`install.extraFiles` / `install.encryptionKeys`:** unused today; the first is
  the natural home for any future non-secret bootstrap file, the second for a
  LUKS key if encryption is ever added (`hosts/netcup/disko.nix` has no LUKS by
  decision). **Source:** <https://devenv.sh/reference/options/#machines>.
- **`--use-machines-as-builders`:** makes declared SSH targets remote builders,
  but requires the C-Nix backend and cannot use `target.sshOpts`. Irrelevant for
  one same-arch host; the relevant switch when `oci` lands. **Source:**
  <https://devenv.sh/machines/>.
- **`secretspec.cachix_auth_token`:** only needed for **private** Cachix caches.
  This repo declares the **public** `devenv.cachix.org` substituter + key
  (`hosts/netcup/self-deploy.nix`), so it buys nothing today. **Source:**
  <https://devenv.sh/integrations/secretspec/> ·
  <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>.
- **`devenv hook` auto-activation + `devenv allow`/`revoke`:** would activate
  `~/nix` on `cd` without direnv, but it is in tension with the
  "use `bin/devenv`, never bare `devenv`" rule and would evaluate the env on every
  `cd`. Current explicit workflow may be the right call. **Source:**
  <https://devenv.sh/auto-activation/>.
- **User config `~/.config/devenv/config.yaml`:** personal, cross-project settings
  (`shell.prompt_prefix`, statusline, keybindings, log behavior);
  `devenv user-config validate`. Orthogonal to the repo, but relevant if the
  `(devenv)` prompt prefix or statusline is ever removed to reduce pane noise.
  **Source:** <https://devenv.sh/tui-customization/> ·
  <https://devenv.sh/blog/2026/09/07/devenv-23-portless-and-tui-configuration/>.
- **`outputs` / `devenv build`:** only matters if something should be packaged and
  distributed rather than activated; no current consumer of a packaged artifact.
  **Source:** <https://devenv.sh/outputs/>.
- **`-O/--option`:** already used for the `target.host` override. Confirmed that
  the type list cannot replace a string list — matching the existing note in
  `devenv.nix:46–52`. `!` replaces lists but only for supported types. **Source:**
  <https://devenv.sh/ad-hoc-developer-environments/>.

---

## Part 2 — Feature reference (what each mechanism is, verbatim where it matters)

This section exists so the list above can be read without re-fetching the pages.

### Machines (2.4, experimental)

Commands, verbatim from <https://devenv.sh/machines/>:

| What you want to do | Command |
|---|---|
| See configured machines | `devenv machines info` |
| Build one without contacting its target | `devenv build machines.server` |
| Check NixOS SSH access changes without building | `devenv machines check server` |
| Install NixOS on a fresh host | `devenv machines install server` |
| Update an existing machine | `devenv machines deploy server` |
| Review now and deploy the same outputs later | `devenv machines plan server`, then `devenv machines apply plan-...` |
| Check or reverse the last NixOS deployment | `devenv machines status server`, `devenv machines rollback server` |

Key rules: NixOS install/deploy require root SSH; nix-darwin may use an admin with
passwordless sudo; a home-manager-only machine may omit `target.host` to activate
locally, while `target.host = "localhost"` still routes through SSH. `install`
wipes disks **without a confirmation prompt** and has no dry run. `plan` records
outputs under `.devenv/machine-plans/<id>/`; `apply` rejects a stale plan.
`status` is one of `pending`, `rolled-back`, `rollback-failed`, `unknown`. The
default deploy deadline is 300 s (`deploy.rollbackTimeout`, range 30–600); the
default health check is `"true"` and verifies only system paths.

### Tasks

`tasks."ns:name"` with `exec`; `after`/`before` build the DAG; suffixes
`@started`/`@ready`/`@succeeded`/`@completed` select how much of a dependency must
be true (`@ready` default for processes, `@succeeded` for oneshot tasks);
`wantedBy` selects which tasks a task runs for, like systemd; `status` skips and
caches; `execIfModified` skips when listed files are unchanged; `input`/outputs
flow through `$DEVENV_TASK_INPUT`, `$DEVENV_TASKS_OUTPUTS`,
`$DEVENV_TASK_OUTPUT_FILE`, and `$DEVENV_TASK_EXPORTS_FILE`; `devenv:enterShell`
and `devenv:enterTest` are built-in lifecycle events; processes are tasks under
`devenv:processes:`; `--mode single|before|after|all`; `devenv tasks list --json`.
Source: <https://devenv.sh/tasks/>.

### Tests

`enterTest` runs on `devenv test` (alias `ci`); processes start/stop around it;
`.test.sh` is auto-detected; `wait_for_port` is provided; `config.devenv.isTesting`
branches config; `--override-dotfile` isolates `.devenv`. Source:
<https://devenv.sh/tests/>.

### Profiles

`profiles.<name>.module`; `profiles.hostname."<host>"` and
`profiles.user."<user>"` auto-activate; `extends` merges; priorities are base <
hostname < user < `--profile` (last flag wins); a profile that reads its own
`config` must be a function. Source: <https://devenv.sh/profiles/>.

### Extending

Define `options.<ns> = { … lib.mkOption … }` and a `config` block with `lib.mkIf`;
consume a central module via `devenv.yaml` `inputs`/`imports`; `disabledModules`
replaces a built-in module. Source: <https://devenv.sh/extending/>.

### Outputs

`outputs.<name>` and `config.lib.types.outputOf`; language `import` functions
package per ecosystem; `devenv build [attr]` prints store paths. Source:
<https://devenv.sh/outputs/>.

### Processes (for the record)

`devenv up` / `down` / `processes {list,status,logs,restart,start,stop,wait,attach}`;
`up -d` detaches; a second `up` attaches; readiness probes (`exec`, `http.get`,
`notify`); `restart.{on,max}`; `shutdown.{signal,grace}`; `watch`; `watchdog`;
socket activation; `process.proxy.enable` with friendly `<process>.<project>.localhost`
URLs and optional HTTPS; `linux.capabilities`; alternative managers via
`process.manager.implementation`. Session-scoped. Source:
<https://devenv.sh/processes/> · <https://devenv.sh/blog/2026/09/07/devenv-23-portless-and-tui-configuration/>.

### YAML keys (verified against the pinned CLI's schema)

Top-level keys in `devenv.schema.json` include `allow_unfree` (**deprecated**),
`allow_broken`, `allow_unsupported_system`, `backend`, `clean`, `imports`,
`impure`, `inputs`, `nixpkgs`, `profile`, `prompt_prefix`, `reload`,
`require_version`, `secretspec`, `shell`, `strict_ports`. `nixpkgs` has
`allow_unfree` (live, added 1.7) among others. `secretspec` has `enable`,
`profile`, `provider`, `cachix_auth_token` (added 2.2). Source:
<https://devenv.sh/devenv.schema.json> · <https://devenv.sh/reference/yaml-options/>.

### SecretSpec

The SecretSpec CLI ships with devenv; recommended runtime pattern
`secretspec run -- <cmd>`; devenv exports `SECRETSPEC_PROFILE` and an explicitly
selected provider; `devenv.yaml` `secretspec.{enable,provider,profile}`.
Source: <https://devenv.sh/integrations/secretspec/>.

---

## Part 3 — Adjacent hygiene found while inventorying (not devenv features)

These are not feature opportunities, but the research surfaced them and they
block or confuse the above:

- `docs/install-netcup.md` Step 5 still says the repo "has no `secretspec.toml`",
  which `devenv.yaml` now contradicts (`devenv.yaml:5–13`).
- `openspec/config.yaml:9–17` PURPOSE still says "there is no tailnet and no
  secret provider in the path", contradicted by the current tree.
- Five untouched specs still carry `Purpose: TBD`
  (`docs/handoff-followups.md` ledger #7).
- `openspec/changes/add-netcup-operator-credentials/` is unimplemented (tasks
  unchecked; no `scripts/operator-credential-seed.sh` in the tree).
- Three coexisting version pins (`bin/devenv` tag, `devenv.yaml` input,
  `hosts/netcup/operator.nix`'s derived package) — `require_version` (item 2)
  makes drift loud, but consolidation is still open.
