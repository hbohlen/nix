# devenv Mechanisms Decision Boundary: Processes, Tasks, Tests, Profiles

> **Purpose**: Answer "which mechanism carries a long-running dev helper, which carries a build/verify pipeline, and which can never survive a reboot?" — verified against upstream docs.
>
> **Sources**: [devenv.sh/processes](https://devenv.sh/processes/), [devenv.sh/tasks](https://devenv.sh/tasks/), [devenv.sh/tests](https://devenv.sh/tests/), [devenv.sh/profiles](https://devenv.sh/profiles/), [devenv.sh/reference/options](https://devenv.sh/reference/options/), [github.com/cachix/devenv](https://github.com/cachix/devenv).

---

## 1. `processes` — Full Capability List & Session Scope

### Capabilities

| Feature | Status | Notes |
|---|---|---|
| Readiness probes | ✅ | `ready_probe` — exec, HTTP, tcp, systemd notify ([blog 2.0](https://devenv.sh/blog/2026/03/05/devenv-20-a-fresh-interface-to-nix/)) |
| Restart policies | ✅ | `restart = { on = "on_failure"\|"always"\|"never"; max = N; window = S; }` ([processes doc](https://devenv.sh/processes/)) |
| Watchdog | ✅ | systemd-compatible — process must send `WATCHDOG=1` to notify socket or be killed/restarted |
| `up -d` (background) | ✅ | `devenv up -d` returns while manager+processes keep running as a daemon |
| Attach | ✅ | Second `devenv up` attaches to a running daemon; `devenv processes attach` for read-only view |
| Proxy (`.localhost`) | ✅ | `process.proxy.enable = true` gives friendly URLs; per-process/Per-port hostname override; HTTPS via mkcert |
| Socket activation | ✅ | **New in 2.0** — `listen = [ { name, kind="tcp"\|"unix_stream", ... } ]` enables zero-downtime restarts & lazy startup |
| File watching | ✅ | Watch paths, re-run on change |
| Linux capabilities | ✅ | **New in 2.3** — `linux.capabilities = [ "net_bind_service" ]` |
| Port allocation | ✅ | Auto-allocates free ports; `--strict-ports` to fail instead of searching |
| Individual control | ✅ | `devenv processes start/stop/restart <name>` |
| Shutdown signaling | ✅ | `shutdown = { signal = 2; grace = 10; }` — per-process graceful stop |

### ⚡ SESSION SCOPE — THE CRITICAL CONSTRAINT

Upstream is explicit:

> **"Processes only live for the duration of the run."**
> — [devenv.sh/tasks/#processes-as-tasks](https://devenv.sh/tasks/#processes-as-tasks)

And:

> *"`devenv tasks run` stops every process it started once the task graph finishes, whether the process is a root or was pulled in as a dependency of another task. Use `devenv up` when you want a process to keep running."*
> — [devenv.sh/tasks/#processes-as-tasks](https://devenv.sh/tasks/#processes-as-tasks)

**What this means in practice**:

| Scenario | What happens to processes |
|---|---|
| `devenv up` (foreground) | Runs until Ctrl-C; all processes stop |
| `devenv up -d` (background) | Daemonizes; processes survive shell exit but **NOT reboot or logout** (daemon lives in `$XDG_RUNTIME_DIR`) |
| `devenv tasks run` | **All started processes are stopped** when the task graph finishes |
| `devenv shell` with `start.enable = "interactive-shell"` | Processes start on shell entry, stop on shell exit |
| Logout / reboot | **All devenv-managed processes die** (no linger, no systemd unit, no init integration) |

The daemon's runtime dir is keyed to `$XDG_RUNTIME_DIR` (or `/run/user/$UID`) which is **destroyed on logout**. From [PR #2927](https://github.com/cachix/devenv/pull/2927):

> *"`DEVENV_RUNTIME` was derived from `XDG_RUNTIME_DIR || TMPDIR || /tmp`... On macOS, where `XDG_RUNTIME_DIR` is unset, this was the default failure mode."*

The daemon is a session-scoped process — not a system service.

---

## 2. `tasks` — The DAG Model

### Core concepts

> *"Tasks allow you to form dependencies between code, executed in parallel."*
> — [devenv.sh/tasks/](https://devenv.sh/tasks/) (added in 1.2)

#### DAG edges: `after` / `before`

```nix
# declared from the dependent task
tasks."myapp:build".after = [ "myapp:generate" ];

# ...is the same edge as declaring it from the dependency
tasks."myapp:generate".before = [ "myapp:build" ];
```

Processes are tasks too — `before`/`after` connects them interchangeably.

#### Dependency states (`@` suffix)

| Suffix | Satisfied when | Failure propagates? |
|---|---|---|
| `@started` | the target has begun executing | yes |
| `@ready` | a process passes its readiness probe; for oneshot tasks this means success | yes |
| `@succeeded` | the target exits with code `0` (or is skipped) | yes |
| `@completed` | the target finishes, regardless of exit code | no (soft dependency) |

> *"When no suffix is given the default is `@ready` for processes and `@succeeded` for oneshot tasks."*
> — [devenv.sh/tasks/#dependencies-between-tasks](https://devenv.sh/tasks/)

#### Execution modes (`--mode`)

| Mode | Runs |
|---|---|
| `single` | only the named task |
| `before` (default) | the task and everything upstream of it (its dependencies) |
| `after` | the task and everything downstream of it |
| `all` | the entire connected graph, both upstream and downstream |

> *"`devenv up` starts processes in `before` mode, while `devenv test` runs in `all` mode."*
> — [devenv.sh/tasks/#execution-modes](https://devenv.sh/tasks/)

#### Other task features

| Feature | Status | Notes |
|---|---|---|
| `wantedBy` | ✅ | **New in 2.3.2** — pull tasks into a run even in `before` mode |
| `status` caching | ✅ | `status` command returns 0 → skip `exec`; outputs cached & restored |
| `execIfModified` | ✅ | Glob patterns; skips task if files unchanged (mtime + hash) |
| `input` / `outputs` | ✅ | Shell messages via `$DEVENV_TASK_OUTPUT_FILE` |
| `devenv tasks list --json` | ✅ | `task.config` generates `tasks.json`; `devenv eval` returns JSON |
| Namespace prefix | ✅ | `devenv tasks run myapp` runs all `myapp:*` tasks |

### Expressing "preflight must pass before anything touches the host"

Use `before`/`after` with `@ready` or `@succeeded`:

```nix
tasks."preflight:check".exec = "...";
tasks."app:deploy".after = [ "preflight:check@succeeded" ];
```

Or use `@completed` for soft dependencies that don't block on success.

### Can tasks replace hand-written shell scripts?

**Yes** — that's their explicit design. Tasks give you: dependency ordering, parallelism, caching (skip work that's already done), status checks, and structured outputs. The `execIfModified` + `status` combo replaces "check if output exists, skip if fresh" boilerplate.

### Documented limits

- `status` and `execIfModified` **cannot** be used together (assertion error in `tasks.nix`)
- `execIfModified` cache **does not detect file deletion** — known bug ([#2577](https://github.com/cachix/devenv/issues/2577)); stale DB entries accumulate
- `status` miss renders as a "failed" activity in the UI (noise in CI) — being addressed ([#2984](https://github.com/cachix/devenv/issues/2984))
- Tasks have **no** concept of "run at boot" or "keep running after command exits"

---

## 3. `tests` — `enterTest` and friends

### How it works

> *"Running `devenv test` will build your environment and run the tests defined in `enterTest`. If you have processes defined in your environment, they will be started and stopped for you."*
> — [devenv.sh/tests/](https://devenv.sh/tests/)

| Feature | Status | Notes |
|---|---|---|
| `enterTest` | ✅ | The test script; runs after shell setup |
| `.test.sh` auto-detection | ✅ | If `.test.sh` exists, `enterTest` runs it |
| Process lifecycle around test | ✅ | Processes started before test, stopped after |
| `wait_for_port` | ✅ | Provided helper for port readiness |
| `config.devenv.isTesting` | ✅ | **Added in 1.0.6** — conditionally include config when testing |
| `--no-tui` | ✅ | Disable TUI for CI/non-interactive |
| `devenv ci` | ✅ | Alias workflow for CI |

### When upstream recommends tasks instead of `enterTest`

> **"Consider using tasks for tests — For more complex test setups with dependencies and better control, consider using tasks with the `before` attribute. Tasks can be configured to run before `devenv:enterTest` and provide better parallelization and dependency management."**
> — [devenv.sh/tests/](https://devenv.sh/tests/)

Use `enterTest` for simple smoke tests. Use tasks when you need:
- Dependency ordering between test setup steps
- Parallel execution
- Caching/conditional re-run
- Setup that runs before processes start (`before = [ "devenv:processes:db@ready" ]`)

---

## 4. `profiles` — Configuration Variants

### Definition

> *"Profiles allow you to organize different variations of your development environment. You can activate profiles manually using CLI flags or have them activate automatically based on your system environment."*
> — [devenv.sh/profiles/](https://devenv.sh/profiles/) (new in 1.9)

### Core options

| Option | Purpose |
|---|---|
| `profiles.<name>.module` | The Nix module merged into the base config |
| `profiles.hostname.<name>.module` | Auto-activates when `hostname` matches |
| `profiles.user.<name>.module` | Auto-activates when `$USER` matches |
| `extends` | Inherit from another profile (chainable) |
| `--profile <name>` | Manual activation (CLI flag) |
| `-P <name>` | Short form |
| `devenv.yaml` / `devenv.local.yaml` | Default profile can be set there |

### Priority order (deterministic)

> *"Base configuration always loads first and has the lowest precedence. Hostname profiles activate next, followed by user profiles. Manual profiles passed with `--profile` have the highest precedence; if you pass several profiles, the last flag wins. Extends chains resolve parents before children."*
> — [devenv.sh/profiles/#profile-priorities](https://devenv.sh/profiles/#profile-priorities)

```
Base → hostname → user → manual (--profile)
```

### Can profiles split 'workstation dev tooling' from 'host tooling'?

**Yes, cleanly** — that's the intended use:

```nix
{
  profiles.workstation.module = {
    languages.javascript.enable = true;
    processes.dev-server.exec = "npm run dev";
  };
  profiles.ci.module = {
    packages = [ pkgs.playwright ];
    env.NODE_ENV = "test";
  };
  profiles.hostname."build-server".module = {
    # auto-activates on that machine
  };
}
```

### Gotchas

- Each profile is a submodule recursively merged into top-level config. To reference `config` values set *within the same profile*, the module **must** be a function: `{ config, ... }: { ... }`. Otherwise `config` refers to the top-level only and won't see profile-local values.
- `devenv --profile backend up` works — but note profiles are about *configuration*, not process lifecycle. A process in a profile still obeys the same session-scope rules.

---

## 5. The Hard Boundary — What Survives Reboot or Logout?

### Explicit answer

> **No devenv mechanism (other than `machines`) survives reboot or logout.**

The project's existing decision — that boot-surviving jobs need NixOS `services.*` or lingered user units — is correct and fully supported by upstream evidence.

### Breakdown by mechanism

| Mechanism | Survives shell exit? | Survives logout? | Survives reboot? |
|---|---|---|---|
| `processes` (`devenv up`) | Only with `-d` | ❌ | ❌ |
| `processes` (`devenv tasks run`) | ❌ (stops when graph finishes) | ❌ | ❌ |
| `tasks` | ❌ (onshots complete, processes stop) | ❌ | ❌ |
| `tests` | ❌ | ❌ | ❌ |
| `profiles` | N/A (config only) | ❌ | ❌ |
| **`machines`** | ✅ | ✅ | ✅ (deploys to NixOS/nix-darwin/home-manager which is a full OS config) |

### Why processes don't survive

The native process manager daemon is a **session-scoped** daemon, not a system service. It:

1. Lives under `$XDG_RUNTIME_DIR/devenv-<hash>/` (cleared on logout)
2. Has no systemd unit, no launchd agent, no linger integration
3. Is spawned by `devenv up -d` and dies with the user session

From the [processes doc](https://devenv.sh/processes/) and confirmed by [issue #2630](https://github.com/cachix/devenv/issues/2630) / [PR #2927](https://github.com/cachix/devenv/pull/2927):

> *"`devenv up -d` can return while the manager and its processes remain running."*

But "remain running" means "remain running **for the rest of the user session**" — not "remain running across reboots." The runtime dir is session-scoped.

### The only exception: `machines`

> *"devenv 2.4 introduces Machines. Define machine configurations alongside your development environment, then build and deploy them with `devenv machines`. It supports: NixOS, nix-darwin, home-manager."*
> — [devenv.sh/blog/2026/09/24/devenv-24-machines](https://devenv.sh/blog/2026/09/24/devenv-24-machines/)

`machines` deploys a full OS configuration (systemd services, launchd agents, etc.) — that's what survives reboot. For anything less than a full machine deployment, devenv has no persistence story.

### Bottom line

For the repo's use case:

- **Long-running dev helper** (dev server, file watcher, db) → `processes` with `devenv up` (or `devenv up -d` + manual restart each session)
- **Build/verify pipeline** (lint, test, build, deploy) → `tasks` (full DAG with caching)
- **Must survive reboot** → `machines` (NixOS/nix-darwin) **or** NixOS `services.*` / lingered systemd user units **outside** devenv

---

## Summary: Use This Mechanism for That Job

| Job | Mechanism | Why | Reboot-survives? |
|---|---|---|---|
| Long-running dev server / db / file watcher | **`processes`** (`devenv up`) | Supervision, readiness probes, restart policies, socket activation, port allocation | ❌ No |
| Background dev stack (shell exit ok) | **`processes`** (`devenv up -d`) | Daemon stays alive until logout/reboot | ❌ No |
| Build / lint / test pipeline | **`tasks`** | DAG, parallel execution, `status`/`execIfModified` caching, dependency ordering | ❌ No |
| Smoke test of env | **`tests`** (`enterTest`) | Simple, processes auto-started/stopped | ❌ No |
| Complex test suite with deps | **`tasks`** + `devenv:enterTest` | Better parallelization and dependency management than bare `enterTest` | ❌ No |
| "I'm on CI vs. my laptop" config | **`profiles`** | Auto-activate by hostname/user, `--profile` overrides | ❌ No |
| Dev tooling that must survive reboot | **`machines`** or **NixOS `services.*`** / **lingered systemd user units** | Full OS-level service management | ✅ Yes |
| Replace a chain of shell scripts | **`tasks`** | Declarative DAG, caching, parallelism, structured outputs | N/A (scripts don't need to persist) |

---

### Cross-check against `devenv-feature-opportunities.md`

| Prior finding | Verified? | Notes |
|---|---|---|
| Item 4 (processes replace shell scripts) | ✅ Confirmed | Tasks + processes cover this; `execIfModified` replaces manual "is it fresh?" checks |
| Item 5 (tasks for pipelines) | ✅ Confirmed | DAG + caching is explicitly designed for this |
| Item 10 (tests) | ✅ Confirmed | `enterTest` for simple, tasks for complex; process lifecycle handled automatically |
| Item 13 (profiles for variants) | ✅ Confirmed | Profiles are config-only; priority order is deterministic; no process lifecycle impact |

**Gaps filled**:
- Exact session-scope semantics of processes (quoted verbatim upstream)
- `tasks` documented limits (`status` vs `execIfModified` mutual exclusion, file-deletion cache bug)
- Hard boundary: confirmed NO devenv mechanism survives reboot except `machines`
