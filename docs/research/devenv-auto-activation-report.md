# devenv Auto-Activation & Trust Mechanism — Ground-Truth Report

**Date:** 2026-09-28
**Sources:** devenv.sh docs, GitHub source (cli.rs, hook.rs, hook.posix.sh, direnvrc), CHANGELOG.md, release notes, issues
**Context:** Repo at `/home/hbohlen/nix` pins devenv v2.4.0 at `./bin/devenv`; ambient PATH has devenv 2.2.2; no `direnv` installed; no `.envrc`

---

## 1. Trust: `devenv allow` / `devenv revoke`

### `devenv allow`

Trusts the current working directory for auto-activation. Writes the absolute path of the project directory to the trust database.

```shell-session
$ cd ~/myproject
$ devenv allow
devenv: allowed /home/user/myproject
```

Can bind profiles:

```shell-session
$ devenv --profile backend --profile observability allow
devenv: allowed /home/user/myproject with profile backend, observability
```

**Source — https://devenv.sh/auto-activation/**:
> *"Before a project can auto activate, you need to explicitly trust it. This is a security measure that prevents untrusted projects from modifying your shell."*

**Source — https://devenv.sh/auto-activation/**:
> *"Navigate to the project directory and run: `$ devenv allow`"*

### `devenv revoke`

Removes trust for the current directory:

```shell-session
$ cd ~/myproject
$ devenv revoke
devenv: revoked /home/user/myproject
```

**Source — https://devenv.sh/auto-activation/**:
> *"To stop a project from auto activating: `$ devenv revoke`"*

### Trust store location

The trust database is a plain-text file at:

```
~/.local/share/devenv/added
```

Respects `$DEVENV_HOME` (added in 2.1.3) and `$XDG_DATA_HOME`.

**Source — https://devenv.sh/reference/environment-variables/**:
> *"DEVENV_HOME — devenv's per-user data directory. Stores GC roots, the trust database, cached keys, and other persistent per-user data. Defaults to `~/.local/share/devenv` (respecting `$XDG_DATA_HOME`)."*

**Source — `devenv/src/commands/hook.rs` (Rust source, via commit diff)**:
> *`fn trust_db_path() -> Result<PathBuf> { Ok(devenv_home()?.join("allowed")) }`*

### Trust DB format

**Current format:** one absolute path per line. Legacy format (`<64-char BLAKE3 hash>:<path>`) is still read for backward compatibility but the hash is ignored — trust is now purely per-directory-path.

**Source — commit `2012662` "hook: stop invalidating trust when devenv.yaml changes"**:
> *"Current format: `<path>` (one path per line). Legacy format: `<64-char-hash>:<path>` — the hash is stripped for backward compatibility..."*
> *"Changing devenv.yaml should not invalidate trust"*

**Source — same commit, test:**
> *`assert!(is_trusted(&abs_str).unwrap()); // after changing devenv.yaml`*

### `devenv allow --from <source>`

Binds a directory to an out-of-tree source so the project activates without a local `devenv.nix`. The trust DB stores JSONL with an optional `from` per entry.

**Source — PR #2940 / CHANGELOG v2.2:**
> *"`devenv --from <source> allow` now binds a directory to an out-of-tree source, so you can use a devenv configuration without a local `devenv.nix`."*

---

## 2. Auto-activation routes

### Route A: Native `devenv hook` (recommended, no direnv required)

**Setup commands per shell:**

| Shell | Command / snippet | Config file |
|-------|-------------------|-------------|
| **Bash** | `eval "$(devenv hook bash)"` | `~/.bashrc` |
| **Zsh** | `eval "$(devenv hook zsh)"` | `~/.zshrc` |
| **Fish** | `devenv hook fish \| source` | `~/.config/fish/config.fish` |
| **Nushell** | `mkdir ($nu.default-config-dir \| path join autoload)` then `devenv hook nu \| save --force ($nu.default-config-dir \| path join autoload/devenv-hook.nu)` | `config.nu` (autoload) |

**Source — https://devenv.sh/auto-activation/**:
> *"devenv includes a built in shell hook that automatically activates your developer environment when you `cd` into a project directory. No external tools required."*

**Source — cli.rs (via web search):**
> *"Print shell hook for auto-activation on directory change. Add to your shell config: bash: `eval \"$(devenv hook bash)\"` # in ~/.bashrc; zsh: `eval \"$(devenv hook zsh)\"` # in ~/.zshrc; fish: `devenv hook fish \| source` # in ~/.config/fish/config.fish; nushell: see `devenv hook nu` # in config.nu"*

**Passing args to the auto-activated shell (since v2.3):**

```bash
# bash
eval "$(devenv hook bash -- --no-tui)"

# fish
devenv hook fish -- --no-tui | source
```

**Source — https://devenv.sh/auto-activation/**:
> *"Place arguments for the auto-activated `devenv shell` after `--`. For example, to disable the TUI in shells started by the Fish hook without changing other `devenv` commands: `devenv hook fish -- --no-tui \| source`"*

### Route B: direnv integration (requires direnv + .envrc)

Create `.envrc` in project root:

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

Then run `direnv allow`.

**Source — https://devenv.sh/integrations/direnv/**:
> *"Create an `.envrc` file in your project directory with the following content: `eval \"$(devenv direnvrc)\"` ... `use devenv`"*

**Source — same page:**
> *"devenv now supports native auto activation without direnv ... For most workflows, `devenv shell` combined with `devenv hook` is the recommended approach."*

### Route C: nix-direnv (separate tool, not devenv-native)

Uses `use flake` or `use nix` from nix-direnv in `.envrc`. This is a third-party tool — devenv's docs mention it only in passing. **NOT** a devenv-provided route.

---

## 3. What exactly gets executed on `cd`?

### Native `devenv hook` route

On **every prompt** (bash/zsh) or **PWD change** (fish/nu), the hook script runs:

1. **`devenv hook-should-activate`** — a hidden subcommand that:
   - Walks up from `$PWD` looking for `devenv.nix` (since v2.2; was `devenv.yaml` before)
   - Checks the trust database (`~/.local/share/devenv/allowed`)
   - Prints the trusted project dir to stdout, or returns exit code 2 if untrusted

2. **If trusted:** spawns a subshell:
   ```sh
   (cd "$project_dir" && _DEVENV_HOOK_DIR="$project_dir" _DEVENV_CALLer=hook _DEVENV_SHELL_HINT=... devenv shell)
   ```
   The `( ... )` subshell means the parent shell's environment is untouched.

3. **If untrusted:** prints hint:
   ```
   devenv: /home/user/myproject is not allowed. Run 'devenv allow' to trust this directory.
   ```

**Source — `devenv/hooks/hook.posix.sh` (verbatim):**
> *"`devenv hook-should-activate` is cheap (static binary), so apart from this guard the hook just runs it every prompt — no result caching, so `devenv allow`/`revoke` take effect on the next prompt without a re-`cd`."*

**Source — same file (verbatim):**
> *`_DEVENV_HOOK_DIR` marks the one shell process the hook itself spawned. Capture it into a non-exported variable, then unset the exported copy so it cannot leak into further descendants (a new tmux/zellij pane, a manually started nested shell, ...) started from this shell later on — those would otherwise inherit it, wrongly conclude they too are hook-spawned, and `exit` on cd-out with nothing around to catch them.*

**Source — `devenv/src/commands/hook.rs` (verbatim):**
> *"The hook runs `devenv hook-should-activate` on every prompt — cheap with the static binary — so there's no per-directory activation cache to invalidate; `devenv allow`/`revoke` take effect on the next prompt automatically."*

**Source — commit `93099d5`:**
> *"cli: walk up parent directories to find devenv.nix. When devenv.nix is missing in cwd, walk up parent directories before erroring."*

### Which `devenv` binary runs?

**CRITICAL:** The hook script calls **bare `devenv`** for both `hook-should-activate` and `shell`. There is **no built-in mechanism** to pin the hook to a specific binary path. Whatever `devenv` resolves to on the current shell's PATH at runtime is what runs.

**Source — `devenv/hooks/hook.posix.sh` (verbatim):**
> `project_dir=$(devenv hook-should-activate 2>/dev/null)`
> `(cd "$project_dir" && ... devenv shell@DEVENV_SHELL_ARGS@)`

Both are bare `devenv` — resolved via PATH at runtime.

### direnv route

The `direnvrc` script uses `command -v devenv` to locate the binary:

```sh
DEVENV_BIN=$(command -v devenv)
```

**Source — `devenv/direnvrc` (verbatim):**
> `if [[ -z ${DEVENV_BIN:-} ]]; then DEVENV_BIN=$(command -v devenv); ... fi`
> `devenv_cmd=("${DEVENV_BIN}")`

Again — whatever `devenv` is on PATH. No built-in pinning mechanism.

### Can any route be forced to use `./bin/devenv`?

**Short answer: Not via any official config knob.** But workarounds exist:

| Route | Can pin to `./bin/devenv`? | How |
|-------|---------------------------|-----|
| **Native hook** | **Yes, via shell-level indirection** | Put `/home/hbohlen/nix/bin` at the front of `$PATH` in your shell rc **before** the `eval "$(devenv hook bash)"` line, OR define a shell function `devenv() { /home/hbohlen/nix/bin/devenv "$@"; }` before the eval |
| **direnv** | **Yes, via `$DEVENV_BIN`** | Set `DEVENV_BIN=/home/hbohlen/nix/bin/devenv` in your shell environment before `direnv` runs, OR modify `.envrc` to set it |
| **direnv (alternative)** | **Yes, via PATH** | Same as native hook — put `./bin` on PATH |

**Source — `devenv/direnvrc` (verbatim):**
> `if [[ -z ${DEVENV_BIN:-} ]]; then DEVENV_BIN=$(command -v devenv); ... fi`

Setting `DEVENV_BIN` externally overrides the PATH lookup.

**NOT DOCUMENTED:** There is no `devenv hook --binary /path/to/devenv` flag or similar. The binary used at runtime is always PATH-resolved.

---

## 4. Activation cost & caching

### The trust check (`hook-should-activate`)

Runs on **every prompt**. Cheap — just a path lookup and a line scan of the trust DB. No Nix evaluation involved.

**Source — `devenv/hooks/hook.posix.sh` (verbatim):**
> *"`devenv hook-should-activate` is cheap (static binary), so apart from this guard the hook just runs it every prompt — no result caching"*

### The Nix evaluation (`devenv shell`)

**Does NOT re-evaluate from scratch every time.** devenv 2.0+ uses incremental Nix evaluation caching:

- SQLite database at `.devenv/nix-eval-cache.db`
- Each evaluated attribute is cached with the files and env vars it touched
- When nothing changed (verified by content hash), the cached result is returned immediately — **sub 100ms**
- Cache invalidates when:
  - Any source file read during evaluation changes
  - Environment variables accessed during evaluation change
  - The devenv version, system, or configuration options change

**Source — https://devenv.sh/blog/2026/03/05/devenv-20-a-fresh-interface-to-nix/:**
> *"When nothing changed (verified by content hash), the cached result is returned immediately without invoking Nix at all."*
> *"The cache invalidates when: Any source file that was read during evaluation changes; Environment variables that were accessed during evaluation change; The devenv version, system, or configuration options change"*

**Source — https://github.com/cachix/devenv README (verbatim):**
> *"Instant environments with incremental Nix evaluation caching (sub 100ms when nothing changed)"*

**Cache control flags:** `--eval-cache` (default on), `--no-eval-cache`, `--refresh-eval-cache`

### `require_version` interaction

`require_version` enforces CLI version compatibility with the modules version (from the `devenv` input in `devenv.yaml`):

```yaml
require_version: true      # match modules version exactly
require_version: ">=2.1"   # constraint string
```

**Source — https://devenv.sh/reference/yaml-options/:**
> *"Version requirement for the devenv CLI. Set to `true` to enforce that the CLI version matches the modules version (from the `devenv` input), or use a constraint string with operators (`>=`, `<=`, `>`, `<`, `=`, or a bare version for an exact match)."*

**Source — CHANGELOG v2.1:**
> *"Added `require_version` field to `devenv.yaml` to enforce a devenv CLI version. Set to `true` to match the modules version, or use a constraint string like `\">=2.1\"` (#2391)."*

**NOT DOCUMENTED explicitly for hooks:** If `require_version` is set and the binary on PATH doesn't match, `devenv shell` (and therefore auto-activation) will fail with a version error. This is the mechanism that makes `bin/devenv` (2.4.0) error out if the ambient `devenv` (2.2.2) is used instead.

---

## 5. Pitfalls & gotchas (documented by upstream)

### Nested shells / terminal multiplexers (tmux / zellij)

**v2.2 fix:** Previously, shells started from an active devenv shell (new tmux pane, SSH session, nested shell) inherited the hook marker `_DEVENV_HOOK_DIR` and incorrectly treated themselves as hook-spawned, causing `exit` on cd-out with nothing to catch them.

**Source — v2.2 release notes (verbatim):**
> *"Fixed the shell hook closing a pane or session in a terminal multiplexer such as tmux or zellij when leaving a project directory. Shells started from an active devenv shell, such as a new pane, an SSH session, or a manually started nested shell, inherited the hook marker and incorrectly treated themselves as hook-spawned. The marker is now consumed and removed from the environment as soon as the intended shell receives it, so it cannot leak to processes started afterward (#2861)."*

**Source — `devenv/hooks/hook.posix.sh` (verbatim):**
> *"Capture it into a non-exported variable, then unset the exported copy so it cannot leak into further descendants (a new tmux/zellij pane, a manually started nested shell, ...)"*

### Non-interactive shells / subshells

The hook checks `$-` / prompt hooks, so it **only fires in interactive shells**. Non-interactive subshells, scripts, and CI runners are unaffected.

**NOT DOCUMENTED explicitly** but implied by the hook design (it's tied to `precmd`/`PROMPT_COMMAND` for bash/zsh and PWD event handlers for fish/nu).

### Subdirectories of a project

The hook **will not nest environments**. While inside a `devenv shell`, navigating into a subdirectory of the same project keeps the current shell.

**Source — https://devenv.sh/auto-activation/ (verbatim):**
> *"The hook will not nest environments. While inside a `devenv shell`, navigating into a subdirectory of the same project keeps the current shell. Only navigating outside the project triggers deactivation."*

### Sibling project activation skip (known bug, fixed in v2.2.x)

**Issue #2944:** When cd-ing *directly* from one trusted devenv project into a sibling trusted devenv project, the first project's shell exits but the second never activates. You land with a plain prompt.

**Source — Issue #2944 (verbatim):**
> *"With the shell auto-activation hook, `cd`-ing *directly* from one trusted devenv project into a sibling trusted devenv project exits the first project's shell but never activates the second."*

**Source — PR #2972 fix (verbatim):**
> *"Stop the POSIX hook from marking the `.devenv/exit-dir` target as already processed after the parent shell follows a hook-spawned cd-out."*

### Re-entering a project after follow-out (known bug, fix in progress)

**Issue #3034:** After the hook follows you out of a project (via `.devenv/exit-dir`), cd-ing straight back into that same project does not re-activate the environment. You have to leave and come back a second time.

**Source — Issue #3034 (verbatim):**
> *"After the hook has **followed you out** of a project ... `cd`-ing straight back into that same project does **not** re-activate the environment. You have to leave and come back a second time."*

### Fish-specific: `status is-login` gate

Some Fish users gate their config behind `status is-login`, which a hook-spawned non-login `fish -i` never satisfies, so deactivation on cd-out failed.

**Source — v2.2 release notes (verbatim):**
> *"Fixed a hook-activated shell sometimes remaining active after leaving a project outside a terminal multiplexer. Deactivation depended on the spawned shell's rc file re-sourcing the hook script, which some configurations skip (for example, a Fish config gated behind `status is-login`, which a hook-spawned non-login `fish -i` never satisfies). Each shell's generated init file now handles leaving the project directly, independently of the user's rc file."*

### CI / non-interactive environments

The native hook only runs in interactive shells, so **CI is unaffected** by auto-activation. Use `devenv shell` or `devenv test` explicitly in CI.

**NOT DOCUMENTED** as a "pitfall" per se, but `devenv test` is explicitly the CI command:

**Source — https://devenv.sh/getting-started/ (verbatim):**
> *"`devenv test` builds your developer environment and makes sure that all checks pass. Useful to run in your continuous integration environment."*

### direnv route: `.direnv` directory

direnv creates a `.direnv` directory with cached profiles and watches. `devenv init` adds `.direnv` to `.gitignore` by default.

**Source — https://devenv.sh/integrations/direnv/ (verbatim):**
> *"The `.direnv` directory will be added to your `.gitignore` file by default when you run `devenv init`."*

### direnv route: manual `direnvrc` updates

If using the pinned `source_url` form (v1.3 and older), the `direnvrc` must be updated manually when devenv changes.

**Source — https://devenv.sh/integrations/direnv/ (verbatim):**
> *"We occasionally make updates to our direnv integration script, also known as the `direnvrc`. From v1.4 and onwards, devenv will use the latest compatible version if set up using the latest method described above."*

### Nushell differences

v2.2 fixed the Nushell hook behaving differently from Bash/Zsh/Fish: outer shells with `DEVENV_ROOT` exported (e.g. via direnv) no longer `exit` when leaving the project, and a manually entered `devenv shell` no longer respawns a nested shell.

**Source — v2.2 release notes (verbatim):**
> *"Fixed the Nushell hook behaving differently from the Bash, Zsh, and Fish hooks: outer shells with `DEVENV_ROOT` exported (e.g. via direnv) no longer `exit` when leaving the project, and a manually entered `devenv shell` no longer respawns a nested shell."*

---

## 6. Recommended setup for a repo that must use `./bin/devenv` (pinned 2.4.0)

Given:
- Ambient PATH has devenv 2.2.2 (lacks `machines`)
- Repo pins devenv v2.4.0 at `/home/hbohlen/nix/bin/devenv`
- No `direnv` installed

### Recommendation: Native `devenv hook` + PATH/function indirection

**Step 1: Generate the hook with the pinned binary**

In `~/.bashrc` (or `~/.zshrc`), before the hook line, ensure `devenv` resolves to the pinned binary:

```bash
# Option A: PATH indirection (preferred — affects all devenv calls)
export PATH="/home/hbohlen/nix/bin:$PATH"

# Option B: shell function (scoped, doesn't affect PATH for other tools)
devenv() { /home/hbohlen/nix/bin/devenv "$@"; }

# Then install the hook (uses whatever devenv resolves to ABOVE)
eval "$(devenv hook bash)"
```

**Step 2: Set `require_version` in `devenv.yaml`**

This enforces that the CLI matches the modules version, giving a clear error if the wrong binary runs:

```yaml
require_version: true
```

**Step 3: Trust the project**

```bash
cd /home/hbohlen/nix
devenv allow   # uses bin/devenv now that PATH is set
```

**Step 4: Add `require_version: true` to `devenv.yaml`**

**Source — https://devenv.sh/reference/yaml-options/ (verbatim):**
> *"Set to `true` to enforce that the CLI version matches the modules version (from the `devenv` input)"*

### Why this works

- The hook script has **bare `devenv`** calls → resolved via PATH at runtime
- Setting PATH before `eval "$(devenv hook bash)"` ensures the hook was *generated* by 2.4.0 AND the bare `devenv` inside it resolves to 2.4.0
- `require_version: true` is a safety net: if somehow the wrong binary runs, you get a clear version error instead of a cryptic `machinesMeta` eval failure
- No `direnv` dependency — the native hook is self-contained

### Why NOT the direnv route here

- Requires installing `direnv` (not currently installed)
- The `direnvrc` uses `command -v devenv` — same PATH issue, same workaround needed
- Upstream docs explicitly say native hook is the recommended approach
- One more moving part (`.envrc`, `.direnv/`, direnv daemon)

### Verifying the right binary runs

```bash
$ cd /home/hbohlen/nix
$ which devenv
/home/hbohlen/nix/bin/devenv

$ devenv --version
devenv 2.4.0+b904dcb
```

If you see `2.2.2`, the PATH indirection is missing or misordered — fix before trusting.
