# devenv shell on a non-NixOS workstation — how far can it carry?

Research date: 2026-09-28. Sources: <https://devenv.sh/> and sub-pages, the options
reference, the SecretSpec integration page, the processes page, the blog posts,
and the `cachix/devenv` GitHub repository.

## 1. What can be declared in `devenv.nix`

For each: one line on what it is + when to use it.

| Option | What it is | When to use it |
|---|---|---|
| `packages` | List of nixpkgs derivations. Each is linked into a profile and **added to PATH on shell activation**; libraries/headers/pkg-config propagate to compilers and linkers. | Every executable, library, or header you need. Preferred over imperative installs. |
| `languages.*` | 50+ built-in language modules that pin a compiler/runtime plus LSP servers, formatters, and linters (e.g. `languages.rust.enable = true;`). | When you want a language toolchain with zero manual version juggling. |
| `env` | Attrset of environment variables set in the shell (e.g. `env.GREET = "hello";`). | Configuration knobs, feature flags, endpoints that tools read from env. |
| `scripts.*` | Named executables dropped into the shell's PATH. Each has `exec` (string or file), optional per-script `packages`, and a `description`. | One-off dev commands (`scripts.test.exec = "pytest";`) that you want tab-completable and self-documenting. |
| `enterShell` | Bash code run once after the shell activates. | Simple greetings, printing a help banner, light env tweaks. **Docs steer complex setup to `tasks` instead.** |
| `pre-commit` / `git-hooks` | First-class `git-hooks.nix` integration. Hook packages are staged, and pre-commit is wired into `.git/hooks` on shell entry. | Replace a hand-rolled `.pre-commit-config.yaml` with declarative, nix-provided hooks. |
| `exports` | **Not a shell-level option.** Exists only on `tasks.<name>.exports` — a list of env-var names a task writes (via `$DEVENV_TASK_EXPORTS_FILE`) for dependent tasks to read. | For inter-task communication inside `devenv tasks run`; has no effect on the shell itself. |
| `outputs` | Top-level attrset (or `outputOf`-typed module options) of Nix derivations for **`devenv build`** consumption, packaging, and distribution. | When you want to ship a Nix package (`devenv build outputs.rust-app`), not to change the shell. |

Sources: [`packages`](https://devenv.sh/packages/), [`basics`](https://devenv.sh/basics/), [`scripts`](https://devenv.sh/scripts/), [`git-hooks`](https://devenv.sh/git-hooks/), [`outputs`](https://devenv.sh/outputs/), [`tasks`](https://devenv.sh/tasks/) (for `exports`), [`reference/options`](https://devenv.sh/reference/options/).

## 2. PATH precedence inside `devenv shell`

- devenv builds a single Nix profile and **prepends its `/bin` to PATH**. From the packages page:
  > "Packages are added to the PATH when you activate the shell."

- The profile path is exposed read-only as **`$DEVENV_PROFILE`**
  > "Points to the Nix store path that has the final profile of packages/scripts provided by devenv." — [`reference/environment-variables`](https://devenv.sh/reference/environment-variables/)

- **Do declared packages shadow system (pacman) binaries of the same name?**
  Generally yes — devenv puts its profile *first* on PATH, so `jq` resolves to the nixpkgs one. But the **exact precedence order is NOT DOCUMENTED** as a hard guarantee.

- A real-world complication: if the user's shell rc sources the Nix profile scripts (which the standard and Determinate installers set up), then `~/.nix-profile/bin` and `/nix/var/nix/profiles/default/bin` also land on PATH. devenv's shell hook re-orders its own profile to the front, but this interaction is not spelled out in the docs. A related Nix issue documents the general class of problem ([NixOS/nix#4152](https://github.com/NixOS/nix/issues/4152)).

- **Can you deliberately prefer the system binary?**
  Yes, in three ways:
  1. **Don't declare the package** — if it's not in `packages`, the system one wins.
  2. **Reorder in `enterShell`** — e.g. `export PATH="$PATH:/usr/bin"` (note: append, not prepend) puts the system dir behind devenv's profile, or explicitly `export PATH="/usr/bin:$PATH"` in front of what the shell hook set. (NOT DOCUMENTED as a recommended pattern, but the mechanism is ordinary shell env.)
  3. **Use `--clean`** — the CLI flag `-c, --clean` "Ignore existing environment variables when entering the shell." Combined with an explicit PATH in `enterShell`, this gives you full control. See `devenv shell --help` and the [CLI options in the README](https://github.com/cachix/devenv/).

## 3. Does devenv require Nix / does it work on Arch?

- **Nix is a hard prerequisite.** The getting-started page leads with it:
  > "1. Install Nix" — [`getting-started`](https://devenv.sh/getting-started/)

- It is distributed via `nix-env`, `nix profile install`, or a NixOS `systemPackages` entry. No separate installer.

- **It works on Arch (and any non-NixOS Linux), macOS, WSL2, and NixOS.** From the README:
  > "100,000+ packages from Nixpkgs for Linux, macOS, x64, and ARM64 (including WSL2)" — [`github.com/cachix/devenv`](https://github.com/cachix/devenv/)

- The README also runs a FOSDEM talk's workflow that is exactly this: "Nix using determinate systems installer" on a non-NixOS Linux box, then `devenv shell`.

- **Documented caveats for non-NixOS hosts:**
  - The Nix store is read-only, so tools like `setcap` (e.g. letting Caddy bind port 80/443) **fail on store paths**. The [NixOS wiki Devenv page](https://wiki.nixos.org/wiki/Devenv) documents the workaround: copy the binary to a writable location, then `setcap` the copy, and point the process at the copy.
  - Privileged ports: on Linux devenv's native process manager can grant capabilities (`processes.web.linux.capabilities = ["net_bind_service"];`), which authenticates via `sudo` once and keeps a privileged broker alive for the manager's lifetime — works on non-NixOS too. See [`processes`](https://devenv.sh/processes/).
  - Determinate Nix on single-user mode is fine; devenv uses its own embedded `cachix/nix` C-FFI backend.

- No Arch-specific caveats are documented beyond the general Nix-on-Linux requirements.

## 4. Secrets via SecretSpec

From the [SecretSpec integration page](https://devenv.sh/integrations/secretspec/):

- **Philosophy:** SecretSpec separates secret *declaration* (`secretspec.toml`) from *provisioning* (per-developer/provider).

- **Recommended runtime pattern** — secrets are **NOT loaded into the shell by default**; they reach a process only at exec time:
  > "Load secrets at runtime and expose them only to the processes that need them"
  > ```
  > $ devenv shell
  > $ secretspec run -- npm start
  > ```
  > "This approach: Keeps secrets out of your shell environment; Reduces exposure of sensitive data; Makes secret rotation easier; Follows the principle of least privilege."

- **`SECRETSPEC_PROFILE`** — devenv exports this into the shell when the integration is enabled:
  > "devenv also exports the resolved profile as `SECRETSPEC_PROFILE`."

- **`SECRETSPEC_PROVIDER`** — exported **only when a provider is explicitly selected**:
  > "If you explicitly select a provider through devenv, it also exports that override as `SECRETSPEC_PROVIDER`."
  > Changed in 2.2.2: devenv no longer infers the provider from evaluation-time resolution; only explicit overrides are exported.

- **`devenv.yaml` keys:**
  > ```yaml
  > secretspec:
  >   enable: true
  >   provider: keyring   # keyring, dotenv, env, 1password, lastpass
  >   profile: default    # profile from secretspec.toml
  > ```
  CLI flags (`--secretspec-provider`, `--secretspec-profile`) take precedence over `devenv.yaml`. Env vars `SECRETSPEC_PROVIDER` / `SECRETSPEC_PROFILE` also work.

- **Can a shell read secrets directly?** Yes, but it's discouraged. You can reference them inside `devenv.nix`:
  ```nix
  { config, ... }: { env.DATABASE_URL = config.secretspec.secrets.DATABASE_URL or ""; }
  ```
  This stashes the secret into an env var for the whole shell session — exactly what the docs tell you to avoid for sensitive material.

- `secretspec.cachix_auth_token` (added 2.2) is a separate built-in secret for **private** Cachix caches and irrelevant when using the public `devenv.cachix.org` substituter.

## 5. What `devenv shell` does NOT give you (system/daemon layer required)

These are **out of scope for the shell** and must live in the NixOS machine declaration,
lingered user units, pacman, or similar:

- **Background daemons that survive logout/reboot.** `devenv up -d` detaches, but the manager is session-scoped; when the session ends, the processes die. For always-on services (an agent runner, a DB that must survive a reboot), use NixOS `services.*` or `loginctl enable-linger` user systemd units.
- **System-wide PATH outside the shell.** Only processes spawned from the `devenv shell` (or via direnv auto-activation) get the devenv profile. A cron job, a systemd unit, or a TTY that never entered the shell sees none of it.
- **GUI applications.** No `.desktop` files, no Wayland/X11 session management, no tray icons. You can *build* a GUI app with `devenv`, but launching it in the desktop session is external.
- **Kernel-level / system-global state.** `sysctl` tweaks, kernel modules, `iptables`/`nftables` rules, routing tables, `/etc/hosts`, `tmpfiles.d`, `modprobe` config, `capabilities` persistently on the host binary — none of this is touched by devenv.
- **Privileges that require root on the host.** `setcap` on a Nix store path fails (read-only store). Persistent `systemd` services with `CapabilityBoundingSet`. Mounting filesystems (e.g. LUKS, Disko) at boot.
- **Docker / OCI runtime orchestration.** `devenv container` builds/runs one container, but it is not a replacement for a running `dockerd` or podman system service.
- **Cross-session persistent state.** `$DEVENV_STATE` is per-project; anything that must survive a reboot (e.g. a Postgres data dir you don't want to rebuild) needs a stable, backed-up location the shell doesn't provide.

## 6. Interactions worth knowing

- **Leak into child processes?** Yes — trivially. It is a normal shell with exported env vars (`env.*`, `$DEVENV_PROFILE/bin` on PATH, `SECRETSPEC_PROFILE`, etc.). Any child process inherits them. This is standard Unix env inheritance, not a devenv quirk.

- **Terminal multiplexers (tmux / zellij)?** devenv 2.2+ fixed a class of bug where the shell-hook marker leaked into new panes/SSH sessions/nested shells and caused them to be incorrectly closed on `cd`. The marker is now consumed and removed on receipt so it can't leak to later processes ([v2.2 release notes](https://github.com/cachix/devenv/releases/tag/v2-2), #2861). A pane spawned *inside* an active `devenv shell` inherits its env vars as any child process does.

- **Does it persist across `cd` out of the project?**
  - **Native shell hook / direnv:** leaving the project directory deactivates the environment. With direnv, `cd` out unloads. With the native hook, deactivation is handled by each shell's generated init file.
  - **Manually entered `devenv shell`:** it is just a subshell; `cd` does not deactivate it, and env vars remain set in that shell process for its lifetime.

- **What happens to processes started inside it when the shell exits?**
  - `devenv up -d` (detached): the native process manager keeps running; you can `devenv up` again in another terminal to re-attach. It survives the original shell.
  - `devenv up` (foreground / TUI): a guardian performs shutdown if devenv is killed.
  - `devenv tasks run`: it stops every process it started when the graph finishes — processes are **not** left running beyond the task's lifetime.
  - Background jobs you manually launched (`&`) receive SIGHUP when the shell exits, same as any shell.

- **Nested shells:** devenv 2.2 hardened behavior — a manually entered `devenv shell` on top of an already-active one does not stack another shell on top.

## Bottom line: what must live outside the shell

Keep these in the NixOS `machines` declaration (or lingered user units), not in `devenv.nix`:

1. Always-on daemons / agent runners that must survive logout and reboot.
2. Host networking and firewall (`iptables`/`nftables`, `/etc/hosts`, sysctl).
3. Kernel modules, `modprobe`, LUKS/Disko at boot, `tmpfiles.d`.
4. GUI / desktop session integration.
5. Systemd system services (Postgres, Caddy, nginx as a system service).
6. Privileged capabilities on host binaries (work around the read-only store).
7. Stable, reboot-surviving data directories.
8. Global PATH for cron / non-shell processes.

Nearly everything else — language toolchains, CLI tools, env vars, dev-time processes,
pre-commit hooks, scripts, secrets at runtime — fits inside `devenv shell`.
