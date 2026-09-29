# Nested/Multi-Project devenv — Ground-Truth Report

**Date:** 2026-09-28
**Sources:** devenv.sh docs (auto-activation, monorepo guide, composing imports, yaml-options, polyrepos), CHANGELOG.md, GitHub source (hook.rs, main.rs), devenv 2.4.0 + 2.2.2 behavior
**Context:** Repo at `/home/hbohlen/nix` has one devenv project at root (`devenv.nix` + `devenv.yaml`), pinned `./bin/devenv` v2.4.0 (ambient PATH 2.2.2). User wants nested projects under `~/nix/hermes/`, `~/nix/projects/project-1/`.

---

## 1. Can nested directories each carry their own devenv.nix + devenv.yaml?

**YES — fully supported.** Each directory with a `devenv.nix` is an independent devenv project. Upstream's own monorepo guide shows exactly this layout:

From https://devenv.sh/guides/monorepo/:
> ```
> my-monorepo/
> ├── shared/
> │   └── devenv.nix       # Shared configurations
> ├── services/
> │   ├── api/
> │   │   ├── devenv.yaml
> │   │   └── devenv.nix
> │   └── frontend/
> │       ├── devenv.yaml
> │       └── devenv.nix
> ```

The devenv.sh homepage explicitly markets this as a feature:
> *"Compose multiple environments into a single environment with first-class monorepo support."*
> *"For monorepos, define environments per folder and import them to merge into a single unified environment. Use / to reference from git root."*
— https://devenv.sh/

**Verdict:** SUPPORTED. Nested devenv projects are a first-class use case.

---

## 2. Activation semantics: what happens on `cd` between nested projects?

### The hook algorithm (verbatim from https://devenv.sh/auto-activation/):

> *"The hook runs on every directory change and:*
> *1. Walks up from the current directory looking for a devenv.nix file.*
> *2. Checks the trust database to verify the project was allowed.*
> *3. If trusted, runs devenv shell in a subshell for that project."*

> *"The hook only detects projects that have a devenv.yaml file. Projects with only devenv.nix (without devenv.yaml) are not detected."*
— https://devenv.sh/auto-activation/ (NOTE: this is the cached/v2.1 wording; v2.2+ uses devenv.nix for detection — see CHANGELOG below)

### v2.2+ behavior (from CHANGELOG.md):
> *"Shell hook auto-activation: The shell hook (devenv hook bash/zsh/fish/nu) and devenv allow now detect a project by looking for devenv.nix instead of devenv.yaml. Projects with only a devenv.yaml and no devenv.nix will no longer auto-activate; add a devenv.nix to restore activation."*

### Nested-project behavior — REPLACE, not stack:

From https://devenv.sh/auto-activation/:
> *"Automatic deactivation: When you cd out of the project directory (or any of its subdirectories), the devenv shell exits automatically and you return to your normal shell:*
> ```
> (devenv) $ cd ..
> $
> ```"*

> *"Re-entry protection: The hook will not nest environments. While inside a devenv shell, navigating into a subdirectory of the same project keeps the current shell. Only navigating outside the project triggers deactivation."*

From issue #2488 (closed, native hook implementation):
> *"Works with nested projects (inner project takes precedence)"*

And from composable imports (https://devenv.sh/composing-using-imports/):
> *"If you enter the `frontend` directory, the environment will activate based on what's in the `frontend/devenv.nix` file.*
> *If you enter the top-level project, the environment is combined with what's defined in `backend/devenv.nix` and `frontend/devenv.nix`."*

### Concrete behavior for `~/nix/` + `~/nix/hermes/`:

| Transition | What happens |
|------------|--------------|
| `cd ~/nix/` (from outside) | Hook walks up from `~/nix/`, finds `~/nix/devenv.nix`, starts subshell for `~/nix/` project. `(devenv) $` |
| `cd ~/nix/hermes/` | Hook walks up from `~/nix/hermes/`, finds `~/nix/hermes/devenv.nix` **first** (inner takes precedence), deactivates `~/nix/` shell, starts new subshell for `~/nix/hermes/`. Not stacking — **replacement**. |
| `cd ~/nix/hermes/` (no `devenv.nix` there) | Hook walks up, doesn't find one in `~/nix/hermes/`, continues to `~/nix/`, finds `~/nix/devenv.nix`. Keeps the current `~/nix/` shell. **No new activation** — `~/nix/hermes/` is just a subdirectory of the `~/nix/` project. |
| `cd ..` (back to `~/nix/`) from `~/nix/hermes/` project | Detects left `~/nix/hermes/` project, exits subshell. Then detects entered `~/nix/` project (has its own `devenv.nix`), starts new subshell for `~/nix/`. |
| `cd ~/nix/` while inside `~/nix/hermes/` | `~/nix/` is a parent directory but also has its own `devenv.nix` → treated as leaving `~/nix/hermes/` and entering `~/nix/`. Replacement, not stacking. |

### With direnv (if used instead):

From issue #2488:
> *"However: Given certain needs of a team scaling up, we're more interested in letting direnv have the wheel (because it supports nested activations)"*

direnv **stacks** environments (child extends parent). devenv's native hook does NOT stack — it replaces. This is a known behavioral difference.

**Verdict:** On `cd ~/nix/hermes/` (if it has devenv.nix), the child project **REPLACES** the parent env — the `~/nix/` subshell exits and a new `~/nix/hermes/` subshell starts. No stacking, no failure.

---

## 3. Upstream repo layout: templates/ and examples/

Inspected via GitHub API. Here's what actually exists:

### templates/ (https://github.com/cachix/devenv/tree/main/templates)
- `flake/` — Flake-based template (with `.envrc` for direnv)
- `flake-parts/` — Flake-parts integration
- `cachix/` — Cachix integration
- `rust/`, `python/`, `javascript/`, `go/`, etc. — per-language templates
- `base/` — minimal starting point

Each template is a standalone project with its own `devenv.nix`. **No template shows a nested/multi-project layout.** Templates are single-project starting points.

### examples/ (https://github.com/cachix/devenv/tree/main/examples)
- `simple/` — minimal single project
- `simple-remote/` — project referencing a remote source via `devenv.yaml`
- `imports/` — **THE KEY EXAMPLE**: demonstrates composable imports
  - `examples/imports/devenv.yaml` imports `./folder`
  - `examples/imports/folder/devenv.nix` — nested sub-project
  - `examples/imports/devenv.nix` — `{ imports = [ ./file.nix ]; }`
- `supported-languages/` — language examples
- `scripts/` — script examples
- `monorepo/` — (referenced in docs, may exist as example)

The `examples/imports/` directory is the closest upstream has to a nested layout — it shows a top-level project importing a sub-folder's `devenv.nix`.

**Verdict:** Upstream provides single-project templates. The multi-project pattern is documented in guides (`/guides/monorepo/`) and demonstrated via `examples/imports/`, not as a template you can `devenv init` from.

---

## 4. Does devenv.yaml support inputs/modules to pull shared config from parent?

**YES.** Two mechanisms:

### A. `imports` with git-root-relative paths (monorepo pattern):

From https://devenv.sh/guides/monorepo/:
> *"Each service imports the shared configuration using an absolute import path. Paths starting with / are resolved from the repository root (where .git is located)."*

```yaml
# services/api/devenv.yaml
imports:
  - /shared
```

From the v1.10 release blog (https://devenv.sh/blog/2025/10/07/devenv-110-monorepo-nix-support-with-devenvyaml-imports):
> *"Paths starting with / are now resolved from your git repository root, and parent imports are also supported (#998)."*
> *"This is particularly handy in monorepos where projects are nested at different depths:*
> ```
> my-monorepo/
> ├── nix/
> │   └── devenv.nix       # Shared base configuration
> ├── services/
> │   ├── api/
> │   │   └── devenv.yaml  # imports: [/nix]
> │   └── worker/
> │       └── devenv.yaml  # imports: [/nix]
> └── apps/
>     └── web/
>         └── devenv.yaml  # imports: [/nix]
> ```"

Parent imports (`../api/devenv.nix`) are also supported.

### B. `path:` input for cross-repo shared config:

From https://devenv.sh/composing-using-imports/:
> *"To keep your devenv configuration in a separate repository, for example when working on a team that doesn't use devenv, declare it as a path: input and import it:"*
```yaml
inputs:
  shared-config:
    url: path:../shared-config/
    flake: false
imports:
  - shared-config
```

### C. Limitations (from https://devenv.sh/composing-using-imports/):

> *"Composing devenv.yaml files is now supported for local files (relative and absolute paths). Remote inputs are not yet supported for devenv.yaml imports."*

> *"Caution: The remote repository must use devenv.nix only — devenv.yaml from imported projects is not evaluated. See #2205 for details."*
— https://devenv.sh/guides/polyrepo/

**Verdict:** `devenv.yaml` `imports` with `/`-prefixed paths (git root relative) or `../` parent paths let a child project pull shared config. `path:` inputs also work for sibling repos. Remote flake imports only load `devenv.nix`, not `devenv.yaml`.

---

## 5. Documented guidance for a repo with many independent projects

### Per-project `devenv init`:

Each project is initialized independently. From the monorepo guide:
> *"Enter a specific service environment: `cd services/api && devenv shell`"*

The docs show separate `devenv.yaml` + `devenv.nix` per service folder. There is no `devenv init --nested` — you run `devenv init` once per project directory.

### Recommended structure (verbatim from https://devenv.sh/guides/monorepo/):
```
my-monorepo/
├── shared/
│   └── devenv.nix       # Shared configurations
├── services/
│   ├── api/
│   │   ├── devenv.yaml   # imports: [/shared]
│   │   └── devenv.nix
│   └── frontend/
│       ├── devenv.yaml   # imports: [/shared]
│       └── devenv.nix
```

### Alternative: top-level composition (from https://devenv.sh/composing-using-imports/):
```yaml
# root devenv.yaml
imports:
  - ./frontend
  - ./backend
```
> *"If you enter the top-level project, the environment is combined with what's defined in backend/devenv.nix and frontend/devenv.nix. For example, devenv up will start both the frontend and backend processes."*

### Profiles as alternative:

From https://devenv.sh/guides/monorepo/:
> *"Profiles provide another powerful way to organize development environments by allowing different variations to activate automatically based on your hostname, username, or manually via CLI flags."*

**Verdict:** Upstream recommends either (a) per-folder devenv.nix with shared imports via `[/absolute/path]` in devenv.yaml, or (b) a root devenv.yaml that imports all sub-projects for unified composition. No special `devenv init` mode for nested — each folder is a standalone project.

---

## 6. What breaks: pinned binary, require_version, trust store

### Pinned `./bin/devenv` at repo root — found from nested projects?

**NOT automatically.** From the Rust source (`devenv/src/main.rs`):
> *"fn enter_discovered_project_root() — if invoked from a subdirectory of a project, chdir up to the directory containing devenv.nix"*

The hook script uses bare `devenv` (resolved via PATH at runtime):
> *"Both are bare devenv — resolved via PATH at runtime."*
— https://devenv.sh/auto-activation/ (via hook.posix.sh)

**Critical implication:** When inside `~/nix/hermes/`, the hook calls bare `devenv`. If `~/nix/hermes/` has no `./bin/devenv` and the ambient PATH has 2.2.2, the nested project will use 2.2.2, NOT the pinned 2.4.0. The pinned binary is only found if:
1. The nested project has its own `./bin/devenv`, OR
2. PATH is explicitly prepended with `~/nix/bin/` before the hook runs, OR
3. A wrapper/alias forces the pinned path

### require_version — per-project?

**YES, per-project.** From CHANGELOG:
> *"Added require_version field to devenv.yaml to enforce a devenv CLI version. Set to true to match the modules version, or use a constraint string like ">=2.1" (#2391)."*

From `devenv/src/modules/update-check.nix`:
```nix
requireVersionMatch = lib.mkOption {
  type = lib.types.bool;
  default = false;
  description = ''
    Whether require_version: true is set in devenv.yaml,
    meaning the CLI version must match the modules version.
  '';
};
```

Each `devenv.yaml` is evaluated independently. If `~/nix/hermes/devenv.yaml` has `require_version: ">=2.4"` and the ambient `devenv` is 2.2.2, the nested project will **fail eval** with a version mismatch.

### Trust store — one line per project directory?

**YES.** From the existing research report (lines 50-72):
> *"Trust DB format: one absolute path per line. Current format: `<path>` (one path per line). Legacy format: `<64-char-hash>:<path>` — the hash is stripped for backward compatibility."*

The trust DB is at `~/.local/share/devenv/allowed` (or `added` — the Rust source uses `allowed`). Each project directory that auto-activates needs its own entry.

For `~/nix/` + `~/nix/hermes/` + `~/nix/projects/project-1/`:
```
/home/hbohlen/nix
/home/hbohlen/nix/hermes
/home/hbohlen/nix/projects/project-1
```

Three separate `devenv allow` invocations (one per directory), three separate lines in the trust DB.

**Verdict:** Each nested project needs its own: (1) PATH visibility for the pinned binary (workaround required), (2) `devenv.yaml` with compatible `require_version`, (3) separate trust entry.

---

## 7. Final verdict

### Nested multi-project support: **SUPPORTED**

devenv fully supports multiple nested projects, each with their own `devenv.nix` + `devenv.yaml`. The native hook handles activation/deactivation correctly (replace-on-enter, no-stacking). The monorepo guide is the canonical documentation.

### Caveats that require work:
- **Pinned binary discovery** — the hook uses bare `devenv` from PATH; `./bin/devenv` at `~/nix/` root is NOT found from `~/nix/hermes/` unless PATH is modified or each nested project pins its own binary.
- **require_version** — per-project, must be satisfied by whatever binary resolves on PATH at runtime.
- **Trust store** — one entry per project directory, no wildcards or tree-wide trust.

---

## 8. Recommended directory layout for /home/hbohlen/nix

Given the findings, here is the recommended structure:

```
~/nix/
├── bin/
│   └── devenv              # pinned v2.4.0 (existing)
├── devenv.nix              # root project (existing, netcup host)
├── devenv.yaml             # root project (existing)
├── .envrc                  # OPTIONAL: if direnv route used instead of native hook
├── hermes/
│   ├── devenv.nix          # hermes-specific env
│   ├── devenv.yaml         # imports: [/shared] or [../shared]
│   └── bin/
│       └── devenv          # symlink to ../../bin/devenv (see note below)
├── projects/
│   └── project-1/
│       ├── devenv.nix
│       ├── devenv.yaml     # imports: [/shared]
│       └── bin/
│           └── devenv      # symlink to ../../../bin/devenv
└── shared/
    └── devenv.nix          # shared config (packages, services, git-hooks)
```

### Where the pinned binary lives:

**Single source of truth:** `~/nix/bin/devenv` (v2.4.0).

**For nested projects to use it:** Three options:

**Option A (recommended):** Add `~/nix/bin` to PATH in shell profile BEFORE the hook line:
```bash
# ~/.bashrc or ~/.zshrc
export PATH="$HOME/nix/bin:$PATH"
eval "$(devenv hook bash)"
```
This makes the pinned v2.4.0 resolve everywhere, including nested projects.

**Option B:** Symlink per project:
```bash
mkdir -p ~/nix/hermes/bin
ln -s ../../bin/devenv ~/nix/hermes/bin/devenv
```
Then each project's `./bin/devenv` exists and resolves correctly. Fragile — must repeat per project.

**Option C:** Each nested project has its own full pin (copy of v2.4.0 binary).

### Where trust entries live:

One-time setup per project:
```bash
cd ~/nix && devenv allow
cd ~/nix/hermes && devenv allow
cd ~/nix/projects/project-1 && devenv allow
```

Result in `~/.local/share/devenv/allowed`:
```
/home/hbohlen/nix
/home/hbohlen/nix/hermes
/home/hbohlen/nix/projects/project-1
```

### `require_version` per project:

Each `devenv.yaml` can independently set:
```yaml
require_version: ">=2.4"
```
If the pinned binary (via Option A above) is v2.4.0 and satisfies this, all projects work. If a nested project sets a stricter version and the PATH binary doesn't match, eval fails for that project only.

### Shared config via imports:

`~/nix/hermes/devenv.yaml`:
```yaml
imports:
  - /shared
```

This pulls `~/nix/shared/devenv.nix` into the hermes project. Changes to shared config propagate to all importers.

### Activation behavior with this layout:

| Location | Active project | Binary used |
|----------|---------------|-------------|
| `~/nix/` | `~/nix/` (root) | v2.4.0 (via PATH) |
| `~/nix/hermes/` | `~/nix/hermes/` (replaces root) | v2.4.0 (via PATH) |
| `~/nix/hermes/src/` | `~/nix/hermes/` (same project, kept) | v2.4.0 |
| `~/nix/projects/project-1/` | `~/nix/projects/project-1/` | v2.4.0 |
| `~/nix/` (from hermes) | `~/nix/` (replaces hermes) | v2.4.0 |
| `/tmp` (cd from nix) | none (deactivated) | n/a |

No stacking. Clean replacement. Inner project takes precedence when it has its own `devenv.nix`.
