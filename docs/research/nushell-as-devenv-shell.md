# Nushell as a First-Class devenv Shell — Facts Report

**Date:** 2026-09-28
**Purpose:** Establish from primary sources whether and how `nu` can be a first-class shell inside a devenv environment (with bash fallback), and what breaks / what does not.
**Sources:** devenv.sh docs, devenv GitHub issues/PRs, nushell docs, carapace-sh docs & source, nixpkgs & home-manager modules.

> **Scope:** This is a facts report for a decision the user will make. It does not design the solution.

---

## 1. `devenv hook` — which shells does upstream generate a hook for?

**Exact list (documented):** `bash`, `zsh`, `fish`, `nu` (nushell).

From the [devenv 2.1 release blog](https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/):

> *"devenv 2.1 adds native support for **zsh**, **fish**, and **nushell** ([devenv#2718](https://github.com/cachix/devenv/pull/2718)) with rcfile generation, environment diff tracking, reload hooks, and prompt integration implemented per shell rather than shimmed through bash."*

The per-shell hook invocations, same source and [auto-activation docs](https://devenv.sh/auto-activation/):

| Shell | Hook invocation | Config file |
|---|---|---|
| Bash | `eval "$(devenv hook bash)"` | `~/.bashrc` |
| Zsh | `eval "$(devenv hook zsh)"` | `~/.zshrc` |
| Fish | `devenv hook fish \| source` | `~/.config/fish/config.fish` |
| **Nushell** | `devenv hook nu \| save --force ~/.cache/devenv/hook.nu` then `source ~/.cache/devenv/hook.nu` | `config.nu` |

The nushell hook is a real, first-class hook — not a bash shim. Passing args through the hook (v2.3+) works for bash/fish; nushell arg passthrough is **NOT DOCUMENTED** explicitly.

**Home-manager integration** ([programs/devenv.nix](https://github.com/nix-community/home-manager/blob/master/modules/programs/devenv.nix)) mirrors this exactly: `enableBashIntegration`, `enableZshIntegration`, `enableFishIntegration`, `enableNushellIntegration`, the last sourcing `devenv hook nu` output via `nushell.extraConfig`.

---

## 2. Can `devenv shell` use a non-bash interactive shell — specifically `nu`?

**Yes.** This is the core finding. Since devenv 2.1, the interactive shell is configurable. Three equivalent selectors, in priority order:

### Selector A: `devenv.yaml` `shell` option

From [reference/yaml-options](https://devenv.sh/reference/yaml-options/):

> **`shell`** — *New in version 2.1* — Default interactive shell to use when entering the devenv environment. Can be overridden by the `--shell` CLI flag. Falls back to the `$SHELL` environment variable, then `bash`.
> Supported values: `bash`, `zsh`, `fish`, `nu`. Any other value falls back to `bash`.

```yaml
# devenv.yaml
shell: "nu"
```

### Selector B: `--shell` CLI flag

```sh
devenv shell --shell nu
```

### Selector C: `$SHELL` / `DEVENV_SHELL` environment variable

From [reference/environment-variables](https://devenv.sh/reference/environment-variables/):

> `DEVENV_SHELL` — Added in 2.1 — Shell to use for interactive sessions: bash, zsh, fish, or nu. Mirrors the `--shell` flag.
> `SHELL` — Detects your default shell dialect and resolves the shell binary to launch for `devenv shell` and hooks.

```sh
SHELL=/bin/nu devenv shell   # launches nu directly
```

**Verdict:** `nu` can be the interactive shell of an activated devenv environment through the documented `shell = "nu"` config key, with no workaround required. This is native since v2.1, implemented via per-shell rcfile generation and reload hooks ([devenv#2718](https://github.com/cachix/devenv/pull/2718), closes [#2592](https://github.com/cachix/devenv/issues/2592)).

**Repo context:** The repo pins devenv **2.4.0** (`./bin/devenv`), which is well past the 2.1 threshold. The `shell` option is available.

---

## 3. `enterShell` — what it is, when it runs, and whether it can `exec` a different shell

### What it is

From the [basics](https://devenv.sh/basics/) and [tasks](https://devenv.sh/tasks/) docs:

> *"`enterShell` allows you to execute bash code once the shell activates."*

It is implemented as the `devenv:enterShell` task — it runs before the shell becomes interactive (for `devenv shell`) and before processes start (for `devenv up`). From the [options reference](https://devenv.sh/reference/options/) and [tasks.nix source](https://github.com/cachix/devenv/blob/main/src/modules/tasks.nix):

> *"`devenv:enterShell` runs before the shell is entered (`devenv shell`) and before processes start (`devenv up`)."*

### When it runs

Once, after the Nix environment is built and PATH/env vars are applied, but before the user gets a prompt. It runs **inside** the activated shell (bash by default, or whatever shell is selected).

### Can it `exec` a different interactive shell?

**Mechanically yes; upstream does not document or endorse it.**

`enterShell` takes a string of **bash code**. A user could write:

```nix
enterShell = ''
  exec nu
'';
```

This would `exec` bash → nu. The devenv process that spawned the shell remains the parent; after `exec`, bash is replaced by nu.

### What breaks if you do this

| Concern | Status |
|---|---|
| **PATH / env inheritance** | `exec` preserves the environment, so the devenv profile PATH and `env.*` vars are still set. Works. |
| **devenv's own shell bookkeeping** | The shell hook reload mechanism (v2.1+) runs per-shell prompt hooks. After `exec nu`, the parent bash process that owned those hooks is gone. devenv's hot-reload (`#2595`) was implemented for zsh/fish/nu natively — but an `exec`'d nu would NOT have devenv's generated nu init file sourced (that is only sourced when devenv itself launches nu). Reload would be **broken / NOT DOCUMENTED**. |
| **`devenv processes`** | Runs in a separate daemon process. Unaffected by `exec`. |
| **Deactivation on `cd` out** | With the native hook, deactivation is handled by each shell's generated init file. An `exec`'d nu would not have that init, so **deactivation on leaving the project is NOT DOCUMENTED** and likely broken. |
| **`devenv:enterShell` task ordering** | If `enterShell` is a task dependency for other tasks, `exec` replaces the process and subsequent tasks in the same run would not execute in that shell. |

**Recommendation encoded in the design:** The documented way to get nu as the interactive shell is `shell = "nu"` (Section 2), not `enterShell = "exec nu"`. The latter is a community-pattern workaround that sacrifices hot-reload and clean deactivation.

**Upstream issues:** No upstream issue explicitly discusses `exec nu` from `enterShell`. The nushell support issue ([#2592](https://github.com/cachix/devenv/issues/2592)) explicitly notes the pre-2.1 workaround of `devenv shell nu` (which launched bash, evaluated env, then execs into nu) and its cons: *"If your rcfile touches PATH or other variables, the load order will be incorrect. The system profile will take precedence."* The v2.1 native support was the fix.

---

## 4. carapace + nushell

### Does carapace support nushell?

**Yes, officially.** From the [carapace pkg.go.dev page](https://pkg.go.dev/github.com/carapace-sh/carapace):

> Supported shells: Bash, Cmd (experimental), Elvish, Fish, Ion (experimental), **Nushell**, Oil, Powershell, Tcsh (experimental), Xonsh, Zsh.

The nushell completer lives at [`carapace-sh/carapace/internal/shell/nushell`](https://pkg.go.dev/github.com/carapace-sh/carapace/internal/shell/nushell).

### How it is wired

carapace uses a **hidden command** `_carapace nushell` that emits a nushell script. That script must be sourced. From the [carapace compose.yaml](https://github.com/carapace-sh/carapace/blob/master/compose.yaml):

```yaml
nushell:
  image: ghcr.io/carapace-sh/shell-nushell
  environment:
    RC_NUSHELL: |
      source ~/.cache/example.nu
      $env.config.completions.external.completer = $example_completer
```

The workflow is: `example _carapace nushell` → save output → `source` it → it sets `$env.config.completions.external.completer`.

From the [home-manager carapace.nix module](https://github.com/nix-community/home-manager/blob/master/modules/programs/carapace.nix):

```nix
nushell = lib.mkIf cfg.enableNushellIntegration {
  extraConfig = ''
    source ${
      pkgs.runCommand "carapace-nushell-config.nu" { } ''
        ${bin} _carapace nushell | sed 's|"/homeless-shelter|$"($env.HOME)|g' >> "$out"
      ''
    }
  '';
};
```

Home-manager installs carapace, then adds `extraConfig` to nushell that sources the generated completer snippet.

The NixOS wiki [Nushell page](https://wiki.nixos.org/wiki/Nushell) confirms the pattern:

```nix
programs = {
  nushell.enable = true;
  carapace.enable = true;
  carapace.enableNushellIntegration = true;
};
```

### Does carapace's nushell support need anything beyond the carapace binary?

**No special runtime beyond the carapace binary itself.** The completer snippet (`_carapace nushell`) is self-contained — it registers completions via nushell's external completer mechanism (`$env.config.completions.external.completer`). The only prerequisite is the carapace binary being on PATH. The user already has carapace installed (nix-profile). The wiring is pure nushell config sourcing.

`CARAPACE_SHELL` — **NOT DOCUMENTED** as a carapace env var. The documented env vars are `CARAPACE_BRIDGES`, `CARAPACE_MATCH`, `CARAPACE_HIDDEN`, `CARAPACE_LENIENT`, `CARAPACE_NOSPACE`, `CARAPACE_TOOLTIP`, etc. (from [`env.go`](https://github.com/carapace-sh/carapace/blob/master/internal/env/env.go)). carapace detects the shell from context (the `_carapace <shell>` subcommand called), not from an env var.

---

## 5. Nushell as a shell for AI agents (factual, short)

This is the user's hypothesis. What is **factually true** about non-interactive nushell invocation:

- **`nu -c '<script>'`** runs a script non-interactively. From [stdout_stderr_exit_codes](https://www.nushell.sh/book/stdout_stderr_exit_codes.html): *"`(nu -c 'print hello'; nu -c 'print world') o> test.txt`"* is shown as standard usage.
- **Structured output**: nushell pipelines operate on structured data (records, tables). `ls | where size > 1kb` is native. This is the shell's defining feature vs. POSIX text-stream shells.
- **JSON pipelines**: `to json` / `from json` are built-in commands. `open file.json`, `ls | to json`, `curl ... | from json` are standard patterns.
- **Exit codes**: `$env.LAST_EXIT_CODE` tracks the last external command's exit code (from [special_variables](https://www.nushell.sh/book/special_variables.html): *"The exit code of the last command... Equivalent to `$?` from POSIX"*). `complete` captures stdout/stderr/exit-code in one record. Nu 0.99+: only the final pipeline command can trigger a non-zero exit code error.
- **`$nu.is-interactive`** is `false` when run with `-c` (from [special_variables](https://www.nushell.sh/book/special_variables.html): *"`nu -c "$nu.is-interactive"` → false"*).
- **Startup files**: Non-interactive `nu -c` does NOT read `env.nu`/`config.nu` unless `--login` or explicitly sourced.

**Verdict:** An agent can `nu -c '<pipeline>'`, pipe structured/JSON data out, and inspect `$env.LAST_EXIT_CODE`. The shell is usable for this. Whether it is *better* than bash for agentic use is a hypothesis, not an upstream claim.

---

## 6. NixOS / nixpkgs: `nushell` module

### Is `nushell` in nixpkgs / home-manager?

**Yes, both.**

- **NixOS module:** [`nixos/modules/programs/nushell.nix`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/programs/nushell.nix) (65 lines) — registers the package and installs plugins to `lib/nushell/plugins/` via vendor autoload.
- **Home-manager module:** [`programs/nushell.nix`](https://github.com/nix-community/home-manager/blob/master/modules/programs/nushell.nix) — `programs.nushell.enable`, `configFile`, `envFile`, `environment`, `plugins`, `shellAliases`, etc.

### Documented caveats about nushell as a login shell

From the **NixOS Wiki** [Nushell page](https://wiki.nixos.org/wiki/Nushell):

> *"Using nushell as a login shell is not recommended. Since nushell is not a POSIX shell, it cannot execute the global shell rcfiles, which means that various environment variables that the general NixOS configuration expects to be set will not be set."*

The wiki's recommended workaround is exactly the `exec nu` pattern — but initiated from bash, not from a POSIX-incompatible login shell:

```nix
{ pkgs, ... }: {
  environment.shells = [ pkgs.nushell ];
  programs.bash.interactiveShellInit = ''
    if ! [ "$TERM" = "dumb" ] && [ -z "$BASH_EXECUTION_STRING" ]; then
      exec nu
    fi
  '';
}
```

**The documented caveats:**

| Issue | Source | Detail |
|---|---|---|
| POSIX incompatibility | NixOS Wiki | nu cannot parse `/etc/profile`, `/etc/profile.d/*`, or any POSIX rc file. System env vars set there are **not** sourced. |
| `/etc/profile` not sourced | NixOS Wiki | Since nu is not a login shell in the POSIX sense, the standard `/etc/profile` chain is skipped entirely. |
| sshd shell handling | NOT DOCUMENTED explicitly for nu in nixpkgs | nu's non-POSIX nature means `ssh host 'command'` expects POSIX semantics on the server side. Setting nu as a user's login shell via `users.users.<name>.shell = pkgs.nushell` is allowed by nixpkgs but the downstream effects on `sshd` forced commands, `scp`, and `sftp` are **NOT DOCUMENTED** upstream. |
| Nix env setup | NixOS Wiki | The standard Nix profile scripts (`/nix/var/nix/profiles/default/etc/profile.d/nix.sh`) are bash scripts. If nu is the login shell, these are not sourced, and `nix` command may not be on PATH unless the nix-daemon or a POSIX login shell sourced them. |

The nixpkgs NixOS module itself (65 lines) is minimal — it does NOT configure `config.nu`/`env.nu`/login shell behavior. Those are left to the user or home-manager.

---

## Summary table

| Question | Answer | Source |
|---|---|---|
| Which shells does `devenv hook` support? | bash, zsh, fish, **nu** | [devenv 2.1 blog](https://devenv.sh/blog/2026/05/07/devenv-21-nix-with-zsh-fish-and-nushell-via-libghostty/) |
| Can `devenv shell` use `nu` as its interactive shell? | **Yes**, via `shell = "nu"` in `devenv.yaml` (or `--shell nu`, `$SHELL`, `DEVENV_SHELL`). Native since 2.1. | [yaml-options](https://devenv.sh/reference/yaml-options/), [environment-variables](https://devenv.sh/reference/environment-variables/) |
| What is `enterShell`? | Bash code run once after activation, before the interactive prompt. Implemented as the `devenv:enterShell` task. | [basics](https://devenv.sh/basics/), [tasks](https://devenv.sh/tasks/) |
| Can `enterShell` `exec nu`? | Mechanically yes. **Not documented** as supported. Breaks hot-reload and likely deactivation-on-cd-out. Use `shell = "nu"` instead. | [tasks.nix](https://github.com/cachix/devenv/blob/main/src/modules/tasks.nix), [#2592](https://github.com/cachix/devenv/issues/2592) |
| carapace + nushell? | **Yes.** `carapace _carapace nushell` emits a completer snippet; source it in `config.nu`. Sets `$env.config.completions.external.completer`. No extra runtime needed beyond the carapace binary. | [pkg.go.dev](https://pkg.go.dev/github.com/carapace-sh/carapace), [compose.yaml](https://github.com/carapace-sh/carapace/blob/master/compose.yaml), [hm carapace.nix](https://github.com/nix-community/home-manager/blob/master/modules/programs/carapace.nix), [NixOS wiki Nushell](https://wiki.nixos.org/wiki/Nushell) |
| nushell as agent shell? | `nu -c '<script>'` runs non-interactive. Structured data, `to json`/`from json`, `$env.LAST_EXIT_CODE`, `$nu.is-interactive`. Factually usable; "better than bash" is hypothesis. | [stdout_stderr_exit_codes](https://www.nushell.sh/book/stdout_stderr_exit_codes.html), [special_variables](https://www.nushell.sh/book/special_variables.html) |
| nixpkgs NixOS/home-manager module? | Both exist. NixOS module registers package + plugins. Caveat (wiki): nu as login shell **cannot source `/etc/profile`** (not POSIX). Recommended: stay in bash-login, `exec nu` from `bash.interactiveShellInit`. | [nixos/modules/programs/nushell.nix](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/programs/nushell.nix), [hm nushell.nix](https://github.com/nix-community/home-manager/blob/master/modules/programs/nushell.nix), [NixOS wiki Nushell](https://wiki.nixos.org/wiki/Nushell) |

---

## Bottom line for the repo

1. **`nu` is a first-class interactive shell in devenv 2.4.0.** Put `shell: "nu"` in `devenv.yaml` (or rely on `$SHELL` if nu is the login shell). No `enterShell = "exec nu"` hack needed.
2. **carapace already works with nushell** via `carapace _carapace nushell` + sourcing the output. Only the carapace binary is required. Wiring it into the devenv environment means either (a) home-manager's `carapace.enableNushellIntegration`, or (b) sourcing the snippet inside `enterShell`/`config.nu` after activation.
3. **The NixOS login-shell caveat applies:** if the user sets nu as their *login* shell system-wide, `/etc/profile` is not sourced. The established workaround (NixOS wiki, nixpkgs convention) is to keep bash as login shell and `exec nu` from `bash.interactiveShellInit`. With devenv's `shell = "nu"`, devenv launches nu itself after bash evaluation, so the login-shell concern is separate from devenv — it only matters for the outer OS login shell, which is zsh in this user's case (not nu).
4. **`enterShell` should not be used to `exec nu`** — it sacrifices hot-reload and deactivation. The `shell` option is the supported path.
