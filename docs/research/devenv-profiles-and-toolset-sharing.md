# devenv Profiles and Reusable Toolset Sharing — Upstream Research

> Date: 2026-09-28
> Sources: devenv.sh docs (profiles, monorepo, polyrepo, auto-activation, yaml-options), cachix/devenv GitHub repo (templates, examples, blog post).

---

## 1. Profiles — Full Mechanics

**Source:** https://devenv.sh/profiles/ and https://devenv.sh/blog/2025/09/17/devenv-19-scaling-nix-projects-using-modules-and-profiles/

### Definition

> "Profiles allow you to organize different variations of your development environment. You can activate profiles manually using CLI flags or have them activate automatically based on your system environment."

Define in `devenv.nix`:

```nix
{ pkgs, config, ... }: {
  profiles = {
    backend.module = {
      services.postgres.enable = true;
      services.redis.enable = true;
      env.ENVIRONMENT = "backend";
    };
    frontend.module = {
      languages.javascript.enable = true;
      processes.dev-server.exec = "npm run dev";
    };
    testing.module = { pkgs, ... }: {
      packages = [ pkgs.playwright pkgs.cypress ];
    };
  };
}
```

### Activation methods (verbatim)

**Manual via `--profile`:**

> "Use the `--profile` flag to activate one or more profiles:
> ```sh
> $ devenv --profile backend shell
> $ devenv --profile backend --profile testing shell
> ```"

**Automatic via hostname/user:**

```nix
{
  profiles = {
    hostname."dev-server".module = {
      myteam.services.database.enable = true;
    };
    user."alice".module = {
      myteam.languages.rust.enable = true;
    };
  }
}
```

> "When user alice runs devenv shell on dev-server hostname, both her user profile and the hostname profile automatically activate."

**Default profile via devenv.yaml:**

The `devenv.yaml` reference documents a top-level `profile` option:

> `profile` — "Default profile to activate. Can be overridden by --profile CLI flag. See Profiles." (New in version 1.11)

**Trust-bound profiles (auto-activation):**

From https://devenv.sh/auto-activation/:

> "To activate one or more profiles whenever the project is entered, pass them when allowing it:
> ```sh
> $ devenv --profile backend --profile observability allow
> devenv: allowed /home/user/myproject with profile backend, observability
> ```"

### Priority order (verbatim from blog)

> "To keep profile-heavy projects from fighting each other we wrap every profile module in an automatic override priority. **The base configuration is applied first, hostname profiles stack on top, then user profiles, and finally any manual `--profile` flags**—if you pass several, the last flag wins. Extends chains apply parents before children so overrides land where you expect."

So the full precedence (low → high):

1. **Base configuration** (top-level `devenv.nix` body — lowest)
2. **`profiles.hostname.<name>.module`** (auto-matched by hostname)
3. **`profiles.user.<name>.module`** (auto-matched by username)
4. **Manual `--profile` flags** (highest; last flag wins if multiple)
5. **`extends`** chains: parents applied before children

### `extends`

> "The fullstack profile automatically includes everything from both the backend and frontend profiles through extends."

```nix
{
  profiles = {
    backend.module = { myteam.languages.rust.enable = true; };
    frontend.module = { languages.javascript.enable = true; };
    fullstack.extends = [ "backend" "frontend" ];
  };
}
```

### Config referencing within profiles

Profile modules are recursively merged. If a profile needs to reference `config` values set within itself (not the top-level), use the function form:

```nix
{ config, ... }: {
  profiles.dev.module = { config, ... }: {
    # inner config includes both top-level + profile-specific values
    env.DB_HOST = config.env.PGHOST;
    services.postgres.enable = true;
  };
}
```

---

## 2. Can Profiles Express a TOOLSET?

**Answer: YES — this is exactly what profiles are designed for.**

The blog post's worked example is precisely a team-toolset-as-profile pattern:

> "Teams can define their own set of recommended best practices in a central repository to create even more opinionated environments:
> ```nix
> { lib, config, pkgs, ... }: {
>   options.myteam = {
>     languages.rust.enable = lib.mkEnableOption \"Rust development stack\";
>     services.database.enable = lib.mkEnableOption \"Database services\";
>   };
>   ...
> }
> ```
> ...
> You can enable common defaults globally and use profiles to activate additional components on demand:
> ```nix
> { pkgs, config, ... }: {
>   packages = [ pkgs.jq ];
>   profiles = {
>     backend.module = {
>       myteam.languages.rust.enable = true;
>       myteam.services.database.enable = true;
>     };
>     frontend.module = {
>       languages.javascript.enable = true;
>     };
>     fullstack.extends = [ \"backend\" \"frontend\" ];
>   };
> }
> ```"

**Plain statement:** Profiles are NOT limited to machine/CI variants. They are a general mechanism for *any* variation of a devenv configuration — including toolset selection. The hostname/user auto-activation is just one convenient trigger; the core idea is "named, composable subsets of config that can be activated on demand."

A `workspace` profile carrying shared CLI tools and a `hermes` profile carrying harness tooling would be idiomatic. Use `--profile workspace --profile hermes shell` to combine them, or chain with `extends`.

**Limitation to note:** "Profiles don't work with cross-project references. See #2521 for details." (polyrepo guide). Within a single repo, they work fully.

---

## 3. Sharing Across Projects — Supported Ways, Ranked

When several `devenv.nix` files want the same `packages` list:

### Way 1: Relative/Absolute Imports (RECOMMENDED by upstream)

> "Paths starting with `/` are resolved from the repository root (where `.git` is located), allowing services in different directories to reference shared configurations consistently."
> — https://devenv.sh/guides/monorepo/

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

`devenv.yaml` imports field: "A list of relative paths, absolute paths, or references to inputs to import devenv.nix and devenv.yaml files."

**Rank: BEST for single-repo sharing.** Zero overhead, no extra inputs, works with auto-activation per-directory.

### Way 2: A Shared Nix File Imported by Each devenv.nix

A plain `.nix` file (e.g., `modules/tools.nix`) that each `devenv.nix` imports via relative path or `/`-anchored absolute path:

```nix
# modules/tools.nix
{ pkgs, ... }: {
  packages = [ pkgs.jq pkgs.curl pkgs.ripgrep ];
}

# devenv.nix
{ ... }: {
  imports = [ ./modules/tools.nix ];
}
```

Mechanistically identical to Way 1 but using Nix `imports` inside `devenv.nix` rather than `devenv.yaml`. Functionally equivalent.

**Rank: TIED with Way 1.** Use when you want the shared bit to be a plain Nix module rather than a full devenv project.

### Way 3: Flake Input Exposing Modules

For cross-repo sharing (polyrepos), define a flake input in `devenv.yaml`:

```yaml
inputs:
  myteam:
    url: github:myorg/devenv-myteam
    flake: false
imports:
  - myteam
```

The remote repo's `devenv.nix` becomes a centrally managed module that ships options (with `mkEnableOption`) you enable per-project.

**Rank: BEST for cross-repo/team sharing.** The blog explicitly shows this as the team-best-practices pattern.

### Way 4: Profiles

Profiles CAN express shared toolsets but are weaker for pure sharing — they're activation-bound (a profile only applies when selected), not additive by default. You'd use `extends` to compose, and every consumer must opt in with `--profile`. A shared module via imports is always-on with zero consumer action.

**Rank: LAST for sharing.** Use profiles when the consumer needs to *choose* between variants (backend vs frontend). Use imports when the consumer should *always* get the shared toolset.

---

## 4. OVERFLOW RISK — Large `packages` List

### Verdict: NOT DOCUMENTED

There is NO upstream guidance in devenv docs, blog, or GitHub issues specifying a practical limit on the number of `packages` in a single `devenv.nix`. No thresholds, no warnings about closure size, no granularity recommendations.

### What practitioners actually do:

- **devenv's own devenv.nix** (`https://github.com/cachix/devenv/blob/main/devenv.nix`, 167 lines) keeps a modest packages list — it's a Rust/Nix project, not a kitchen-sink.
- The `supported-languages` example enables ALL 50+ language tooling toggles — but these are `languages.*` options, not `packages` entries. Each language module internally manages its own package set. This is the upstream-preferred way to scale tooling: use `languages.X.enable = true` rather than listing individual packages.
- The blog post's `myteam` module pattern uses `mkIf config.myteam.languages.rust.enable [ pkgs.cargo-watch ]` — conditional, opt-in packages, never a giant unconditional list.

### Practical concerns (not from docs, standard Nix knowledge):

- **Closure size**: every package in `packages` adds to the closure. A 200-package shell will have a multi-GB closure. Nix dedupes identical deps, so overlap helps, but the full closure is what gets substituted/garbage-collected.
- **Evaluation time**: Nix evaluation is generally linear in the number of attributes. A 500-entry `packages` list will add measurable eval time but is unlikely to be the bottleneck (services and languages with heavy option trees are costlier).
- **Store usage**: unrelated packages don't share store paths. A bloated shell wastes disk and slows `nix-store --gc`.

**Recommendation from evidence:** Upstream signals point toward **modules per concern** (not one flat list). Use `languages.X.enable`, `services.X.enable`, and split `packages` into per-module files that get conditionally imported or profile-gated. This keeps each shell's closure small and eval targeted.

---

## 5. REAL EXAMPLES from github.com/cachix/devenv

### Templates (`https://github.com/cachix/devenv/tree/main/templates`)

Three templates:

| Template | URL | Contents |
|----------|-----|----------|
| `flake-parts` | https://github.com/cachix/devenv/tree/main/templates/flake-parts | `.envrc`, `.gitignore`, `flake.nix` — flake-parts based |
| `flake` | https://github.com/cachix/devenv/tree/main/templates/flake | `.envrc`, `.gitignore`, `flake.nix` — basic flake (renamed from "simple" Nov 2025) |
| `terraform` | https://github.com/cachix/devenv/tree/main/templates/terraform | `.envrc`, `.gitignore`, `flake.nix` — Terraform-specific |

Templates are minimal (3 files each, single `flake.nix`). No multi-module examples in templates.

### Examples (`https://github.com/cachix/devenv/tree/main/examples`)

~70 examples, one per language/service. Notable ones for structure:

| Example | URL | Relevance |
|---------|-----|-----------|
| `imports` | https://github.com/cachix/devenv/tree/main/examples/imports | **KEY**: shows `devenv.yaml` with `imports` + `folder/` subdirectory + `file.nix` imported. Demonstrates plain-file imports. |
| `compose` | https://github.com/cachix/devenv/tree/main/examples/compose | **KEY**: root `devenv.yaml` with `imports` pulling in `projectA/` and `projectB/` as separate devenv projects. Root config composes two sub-projects. |
| `scripts` | https://github.com/cachix/devenv/tree/main/examples/scripts | Shows `scripts.*` with a shell script file loaded via `file-script.sh` |
| `supported-languages` | https://github.com/cachix/devenv/tree/main/examples/supported-languages | **KEY**: enables all 50+ language tooling in one file (67 lines) — shows the kitchen-sink pattern, but via toggles not packages |
| `claude-agents` | https://github.com/cachix/devenv/tree/main/examples/claude-agents | AI agent tooling example |
| `hivemind`, `overmind` | process-manager examples | |

The **`compose` example** is the closest to what the user wants: root `devenv.yaml` imports multiple sub-projects, each with their own `devenv.yaml`/`devenv.nix`.

### Docs Guides with Sample Repos

| Guide | URL | Shows |
|-------|-----|-------|
| Monorepo | https://devenv.sh/guides/monorepo/ | `shared/devenv.nix` imported via `imports: [/shared]` from each service |
| Polyrepo | https://devenv.sh/guides/polyrepo/ | Cross-repo composition via flake inputs + imports |
| Using with Flakes | https://devenv.sh/guides/using-with-flakes/ | Multiple `devShells` in one flake (projectA/projectB pattern) |

### Notable Community Repos

No major multi-project community repos were found with the search performed. The canonical multi-project example is the devenv repo's own `examples/compose` and the monorepo guide.

---

## 6. Does Upstream Publish Guidance on Splitting a Large devenv.nix?

### Verdict: NOT DOCUMENTED

There is NO upstream page titled or devoted to "splitting a large devenv.nix." No guide, no blog post, no FAQ entry.

### What practitioners actually do (derived from evidence):

1. **Split by concern into separate `.nix` files imported via `imports`** — each file owns one axis (packages, languages, services, scripts, env).
2. **Use `devenv.yaml` `imports` to compose sub-projects** — the monorepo guide's pattern is the canonical "avoid one giant file" strategy.
3. **Use profiles for on-demand activation** — the blog post's `backend`/`frontend`/`fullstack` pattern lets you avoid loading everything at once.
4. **Prefer `languages.X.enable` / `services.X.enable` over raw `packages`** — the supported-languages example shows 50+ tools enabled via toggles, which internally manage their own package lists per concern.
5. **Use a shared team module (flake input) for cross-project defaults** — the `myteam` module pattern from the blog.

---

## 7. Recommended Structure

For the goal: `~/nix/devenv.nix` at root + `~/nix/modules/*.nix` for tools + `~/nix/projects/<name>/` per project.

```
~/nix/
├── devenv.nix              # Root entry: imports modules, defines profiles
├── devenv.yaml             # Root inputs + imports (optional)
├── modules/
│   ├── workspace.nix       # Shared CLI tools (jq, curl, ripgrep, git, ...)
│   ├── hermes.nix          # Hermes harness tooling (hermes-agent, herdr)
│   ├── caddy.nix           # Caddy service module
│   └── development.nix     # Common languages (nix, rust, python, etc.)
├── projects/
│   ├── projectA/
│   │   ├── devenv.yaml     # imports: [/modules/workspace]
│   │   └── devenv.nix      # project-specific: enables hermes + caddy profiles
│   └── projectB/
│       ├── devenv.yaml     # imports: [/modules/workspace]
│       └── devenv.nix      # project-specific: different toolset
└── hosts/                  # existing host configs (netcup, etc.)
```

### `~/nix/modules/workspace.nix`

```nix
# Shared workspace tooling — always available when imported.
{ pkgs, ... }: {
  packages = [
    pkgs.jq
    pkgs.curl
    pkgs.ripgrep
    pkgs.fd
    pkgs.git
    pkgs.gh
  ];

  # Common env vars for all projects
  env.WORKSPACE_ROOT = builtins.toString ./.;

  # Common git hooks
  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;
    treefmt.enable = true;
  };

  # Common scripts available in every workspace shell
  scripts = {
    fmt.exec = "nixpkgs-fmt .";
  };
}
```

### `~/nix/modules/hermes.nix`

```nix
# Hermes agent harness tooling — opt-in via profile or direct import.
{ pkgs, ... }: {
  packages = [
    pkgs.hermes-agent    # if in nixpkgs or a flake input
    pkgs.herdr
  ];

  # Hermes-specific env
  env.HERMES_HOME = "${builtins.toString ./.}/.hermes";

  # Hermes processes
  processes.hermes.exec = "hermes-agent";
}
```

### `~/nix/modules/caddy.nix`

```nix
# Caddy service module.
{ pkgs, ... }: {
  services.caddy = {
    enable = true;
    # config, vhosts, etc.
  };
}
```

### `~/nix/devenv.nix` (root)

```nix
{ pkgs, config, ... }: {
  # Always-on workspace tooling
  imports = [ ./modules/workspace.nix ];

  # Profiles for on-demand toolsets (activated via --profile)
  profiles = {
    hermes.module = ./modules/hermes.nix;
    caddy.module = ./modules/caddy.nix;
    fullstack.extends = [ "hermes" "caddy" ];
  };
}
```

### `~/nix/projects/projectA/devenv.yaml`

```yaml
imports:
  - /modules/workspace
```

### `~/nix/projects/projectA/devenv.nix`

```nix
{ pkgs, config, ... }: {
  # Project-specific config
  env.PROJECT_NAME = "projectA";

  # Enable hermes profile tools for this project
  imports = [ ../../modules/hermes.nix ];

  # Or enable via profile: devenv --profile hermes shell
}
```

### Selection

- Root workspace: `cd ~/nix && devenv shell` → gets workspace tools
- With hermes: `cd ~/nix && devenv --profile hermes shell` → workspace + hermes
- Project A: `cd ~/nix/projects/projectA && devenv shell` → inherits `/modules/workspace` via devenv.yaml imports
- Project A + hermes: `cd ~/nix/projects/projectA && devenv --profile hermes shell`

---

## Why the Alternatives Lose

**Alternative A — single flat `devenv.nix` with everything**: Becomes unreadable at ~100 lines; every shell pays the closure cost of all tooling regardless of need; no way to activate only what you're working on; merge conflicts in a multi-editor scenario. Upstream's own examples (supported-languages) show that even with 50+ toggles, the file is organized by concern via module options, not one giant `packages` list.

**Alternative B — profiles alone for sharing**: Profiles are activation-gated — a profile only applies when selected, so shared-everything tooling still requires every consumer to pass `--profile workspace`. Imports solve shared-by-default; profiles solve opt-in variants. Using profiles *for* sharing is possible but forces an activation ceremony that imports avoid entirely. The blog post itself uses imports for shared modules and profiles for on-demand variants — the two compose; they aren't interchangeable.

**Alternative C — separate flake inputs per toolset**: Adds flake-input management overhead (locking, pinning, cache misses) for what is functionally identical to a local `.nix` file import. Flake inputs shine for *cross-repo* sharing (team best practices across many repos); for a single-repo setup, relative imports are zero-overhead and simpler. The monorepo guide uses `/shared` imports, not flake inputs, for intra-repo sharing.

**The recommended structure wins** because it uses imports for shared-everything (workspace tools always available), profiles for opt-on variants (hermes, caddy), and per-project directories with their own `devenv.yaml` that import the shared root. This matches every upstream example (`compose`, `monorepo`, profiles blog post) and scales to N projects without any single file growing past ~30 lines.
