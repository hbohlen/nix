# devenv Composition Syntax — Definitive Reference

> **Status:** Verified against upstream docs and source (September 2028)
> **Sources:**
> - https://devenv.sh/reference/yaml-options/
> - https://devenv.sh/composing-using-imports/
> - https://devenv.sh/guides/monorepo/
> - https://devenv.sh/guides/polyrepo/
> - https://devenv.sh/blog/2025/10/07/devenv-110-monorepo-nix-support-with-devenvyaml-imports/
> - https://github.com/cachix/devenv/blob/main/flake.nix (evalModules usage)
> - https://github.com/cachix/devenv/blob/main/flake-module.nix

---

## 1. Does `devenv.nix` support `imports = [ ./path/to/module.nix ];`?

**YES.** This is the standard NixOS module system. devenv uses `nixpkgs.lib.evalModules` internally (verified in `flake.nix` at https://github.com/cachix/devenv/blob/main/flake.nix).

Each imported module **must** be a **function** — NOT a plain attribute set:

```nix
# CORRECT — each imported module is a function
{ pkgs, lib, config, ... }: {
  packages = [ pkgs.curl ];
  env.MY_VAR = "hello";
}
```

**Not** a plain attrset like `{ packages = [ ... ]; }` — that will fail with a type error.

In your main `devenv.nix`:

```nix
{ pkgs, ... }: {
  imports = [
    ./modules/base.nix
    ./modules/dev-tools.nix
  ];
}
```

From nix.dev (https://nix.dev/tutorials/module-system/deep-dive.html):
> The module schema includes the imports attribute, which allows incorporating further modules, for example to split a large configuration into multiple files.

**NOT DOCUMENTED on devenv.sh specifically** — devenv relies on standard NixOS module system semantics and does not document this independently. The module format is assumed knowledge.

---

## 2. What does `devenv.yaml` actually accept?

Complete enumeration from https://devenv.sh/reference/yaml-options/:

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `backend` | `nix` | `nix` | Nix backend |
| `clean.enabled` | `boolean` | `false` | Clean env on shell entry |
| `clean.keep` | `list of string` | `[]` | Vars to keep when cleaning |
| `imports` | `list of string` | `[]` | Paths or input references (see §3) |
| `impure` | `boolean` | `false` | Relax hermeticity |
| `inputs` | `attrset of input` | `{ nixpkgs.url: "github:cachix/devenv-nixpkgs/rolling" }` | Nix inputs |
| `inputs.<name>.url` | `string` | — | URI spec |
| `inputs.<name>.flake` | `boolean` | `true` | Contains flake.nix or devenv.nix? |
| `inputs.<name>.follows` | `string` | — | Inherit another input |
| `inputs.<name>.inputs` | `attrset of input` | — | Override nested inputs |
| `inputs.<name>.overlays` | `list of string` | `[]` | Overlays from input |
| `nixpkgs.*` | various | — | nixpkgs config (allow_unfree, etc.) |
| `profile` | `string` | — | Default profile to activate |
| `prompt_prefix` | `boolean` | `true` | Show `(devenv)` prefix |
| `reload` | `boolean` | `true` | Auto-reload on file change |
| `require_version` | `boolean \| string` | — | CLI version constraint |
| `secretspec.cachix_auth_token` | `boolean \| string` | unset | Cachix auth via secretspec |
| `secretspec.enable` | `boolean` | `false` | Enable secretspec |
| `secretspec.profile` | `string` | — | Secretspec profile |
| `secretspec.provider` | `string` | — | Secretspec provider |
| `shell` | `string` | `$SHELL` or `bash` | Default shell |
| `strict_ports` | `boolean` | `false` | Error on port conflict |

**CRITICAL: There is NO `modules:` key in devenv.yaml.** This is a common misconception. The file uses `imports` (a list of paths/input refs), not `modules`.

From the docs (https://devenv.sh/reference/yaml-options/):
> **imports** — A list of relative paths, absolute paths, or references to inputs to import devenv.nix and devenv.yaml files.

---

## 3. Can `inputs` in `devenv.yaml` be composed?

**YES** — via `imports`. This is the primary mechanism for sharing modules across repos.

### Local (monorepo) imports
```yaml
# devenv.yaml
imports:
  - ./frontend
  - ./backend
  - /shared              # resolved from git root
```

### Remote (polyrepo) imports
```yaml
# devenv.yaml
inputs:
  shared-config:
    url: github:myorg/shared-config
    flake: false
  my-service:
    url: github:myorg/my-service
imports:
  - shared-config
  - my-service
```

**CAVEAT** (from https://devenv.sh/guides/polyrepo/):
> The remote repository must use `devenv.nix` only — `devenv.yaml` from imported projects is not evaluated. See #2205.

For local imports (filesystem paths), **both** `devenv.nix` AND `devenv.yaml` are merged (as of v1.10, https://devenv.sh/blog/2025/10/07/devenv-110-monorepo-nix-support-with-devenvyaml-imports/).

### How a repo exposes modules
A shared repo only needs a `devenv.nix` file. That's it. Combine with `profiles` for per-project variations.

```yaml
# In consuming project's devenv.yaml
inputs:
  myteam:
    url: github:myorg/devenv-myteam
    flake: false
imports:
  - myteam
```

> This automatically includes your centrally managed module.
> — https://devenv.sh/blog/archive/2025 (devenv 1.9 announcement)

---

## 4. Is there an official way to structure `./devenv.nix` plus `./modules/*.nix`?

**YES** — the monorepo guide at https://devenv.sh/guides/monorepo/ shows the canonical pattern:

```
my-monorepo/
├── shared/
│   └── devenv.nix       # Shared configurations
├── services/
│   ├── api/
│   │   ├── devenv.yaml
│   │   └── devenv.nix
│   └── frontend/
│       ├── devenv.yaml
│       └── devenv.nix
```

**shared/devenv.nix:**
```nix
{ pkgs, ... }: {
  packages = [ pkgs.curl pkgs.jq ];
  services.postgres.enable = true;
  git-hooks.hooks.prettier.enable = true;
}
```

**services/api/devenv.yaml:**
```yaml
imports:
  - /shared
```

**services/api/devenv.nix:**
```nix
{ pkgs, ... }: {
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_20;
  };
  env.API_PORT = "3000";
  scripts.dev.exec = "npm run dev";
}
```

> Paths starting with `/` are resolved from the repository root (where `.git` is located).

You can also use `config.git.root` for path construction:
```nix
{ pkgs, config, ... }: {
  processes.api.exec = {
    exec = "npm run dev";
    cwd = "${config.git.root}/services/api";
  };
}
```

---

## 5. How do `packages`, `env`, `scripts`, `enterShell` merge?

**Standard NixOS module system merging** — devenv does NOT customize this. It uses `nixpkgs.lib.evalModules`.

### List options (packages, enterShell prepend/append):
- **Lists concatenate.** Order is by priority (default 1000).
- `mkBefore` (priority 500) — prepends
- `mkAfter` (priority 1500) — appends (this is actually the default behavior for additional modules since they're evaluated after)
- `mkForce` (priority 1) — overrides completely

### Attrset options (env, scripts, profiles):
- **Recursive merge** — inner attrs are merged recursively.
- For inner list values, lists still concatenate.
- `mkForce` overrides the entire value.

### Boolean/string/int options:
- **Last definition with highest priority wins.**
- `mkForce` overrides everything.
- Without priorities, duplicate definitions of a non-list/non-attrset option produce an error (option conflict).

From nix.dev (https://nix.dev/tutorials/module-system/deep-dive.html):
> Because of the way the module system composes option definitions, you can freely assign values to options defined in other modules.

And from nixpkgs docs:
> `mkBefore` and `mkAfter` are equal to `mkOrder 500` and `mkOrder 1500`, respectively.

**NOT DOCUMENTED in devenv-specific docs** — devenv inherits NixOS module system semantics without restating them. The merging behavior is standard NixOS.

### Practical example:

```nix
# modules/base.nix
{ pkgs, ... }: {
  packages = [ pkgs.git pkgs.jq ];
  enterShell = ''
    echo "Welcome!"
  '';
}

# modules/web.nix
{ pkgs, ... }: {
  packages = [ pkgs.curl pkgs.jq ];       # jq is duplicate — module system dedupes
  enterShell = ''
    echo "Web tools ready"
  '';
}
```

Result: `packages = [pkgs.git pkgs.jq pkgs.curl]` (deduped), `enterShell` is both strings concatenated (newline-separated).

```nix
# Force override example:
{ ... }: {
  env.MY_VAR = lib.mkForce "overridden";     # wins over anything else
  packages = lib.mkBefore [ pkgs.emacs ];    # appears first in list
  packages = lib.mkAfter [ pkgs.tmux ];      # appears last in list
}
```

---

## 6. Does devenv have a `devenv.nix` entry-point convention for directory-based modules?

**NO.** `devenv.nix` must be a **file**, not a directory. There is no `default.nix` discovery.

**NOT DOCUMENTED** — this is simply the convention: `devenv.nix` is a single file in the project root (or wherever `--from` points).

Workarounds:
- Use `imports` inside `devenv.nix` to split into `./modules/*.nix`
- Use `devenv --from path:/some/dir` to point at a different project root
- Use `devenv --from github:org/repo?dir=path` for remote

---

## 7. What is NOT DOCUMENTED?

| Topic | Status |
|-------|--------|
| `devenv.nix` `imports = [...]` syntax | **NOT DOCUMENTED** on devenv.sh — standard NixOS module system knowledge assumed |
| `mkBefore` / `mkAfter` / `mkForce` behavior in devenv | **NOT DOCUMENTED** devenv-specific — standard NixOS module system semantics |
| Module shape (function vs attrset) | **NOT DOCUMENTED** on devenv.sh |
| `devenv.nix` as directory (default.nix discovery) | **NOT DOCUMENTED** — it's a file, not directory |
| Merging semantics for list vs attrset options | **NOT DOCUMENTED** devenv-specific — inherited from NixOS |
| Profile merging priority rules | **PARTIALLY DOCUMENTED** (https://devenv.sh/profiles/ explains the 4 tiers) |
| `imports` in devenv.yaml merging both .nix and .yaml | **DOCUMENTED** (https://devenv.sh/blog/2025/10/07/devenv-110-monorepo-nix-support-with-devenvyaml-imports/) |

---

## Recommended Layouts for Shared Toolset + Per-Tool Modules

### Option A: Relative `imports` inside `devenv.nix` (simplest, monorepo-friendly)

```
my-project/
├── devenv.yaml        # inputs only
├── devenv.nix         # entry point with imports
├── modules/
│   ├── base.nix       # shared toolset (git, curl, jq, etc.)
│   ├── python.nix     # python-specific
│   ├── rust.nix       # rust-specific
│   └── web.nix        # web dev tools
```

**devenv.yaml:**
```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
```

**devenv.nix:**
```nix
{ pkgs, ... }: {
  imports = [
    ./modules/base.nix
    ./modules/python.nix
    ./modules/rust.nix
  ];

  # project-specific overrides here
  env.PROJECT = "my-project";
}
```

**modules/base.nix:**
```nix
{ pkgs, ... }: {
  packages = [ pkgs.git pkgs.curl pkgs.jq ];
  enterShell = ''
    echo "Toolset ready"
  '';
}
```

**modules/python.nix:**
```nix
{ pkgs, ... }: {
  languages.python = {
    enable = true;
    version = "3.11";
    venv.enable = true;
  };
}
```

✅ **Pros:** No extra YAML files, works immediately, hot-reload watches all imported files.
❌ **Cons:** Cannot enter sub-directories with partial configs.

---

### Option B: `devenv.yaml` `imports` with git-root paths (docs-endorsed)

```
my-monorepo/
├── shared/
│   └── devenv.nix          # shared toolset
├── tools/
│   ├── python/
│   │   ├── devenv.yaml     # imports: [/shared]
│   │   └── devenv.nix      # python-specific
│   └── rust/
│       ├── devenv.yaml     # imports: [/shared]
│       └── devenv.nix      # rust-specific
└── devenv.yaml             # root imports: [./tools/python, ./tools/rust]
```

**shared/devenv.nix:**
```nix
{ pkgs, ... }: {
  packages = [ pkgs.git pkgs.curl pkgs.jq ];
  git-hooks.hooks.nixpkgs-fmt.enable = true;
  enterShell = ''
    echo "Base toolset ready"
  '';
}
```

**tools/python/devenv.yaml:**
```yaml
imports:
  - /shared
```

**tools/python/devenv.nix:**
```nix
{ pkgs, ... }: {
  languages.python = {
    enable = true;
    version = "3.11";
  };
}
```

**Root devenv.yaml:**
```yaml
imports:
  - ./tools/python
  - ./tools/rust
```

✅ **Pros:** Docs-endorsed (https://devenv.sh/guides/monorepo/), each sub-dir is independently enterable, hot-reload works transitively.
❌ **Cons:** More YAML files to manage.

---

## Quick Reference Card

| Goal | Mechanism |
|------|-----------|
| Split `devenv.nix` into multiple files | `imports = [ ./modules/a.nix ./modules/b.nix ]` |
| Share config across folders in same repo | `devenv.yaml` `imports: [/shared]` |
| Share config across repos | `inputs` + `imports` in `devenv.yaml` |
| Override a list option | `mkBefore` (prepend), `mkAfter` (append), `mkForce` (replace) |
| Override a scalar option | `lib.mkForce "value"` |
| Enable per-project variation | `profiles` option + `--profile` CLI flag |
| Point devenv at a different directory | `devenv --from path:/path/to/project` |
