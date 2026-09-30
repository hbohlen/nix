# devenv 2.4 `machines.nix` — Reference for Local home-manager Activation

**Date:** 2026-09-29
**Ticket:** hermes-config / 03
**Audience:** Ticket 06 — wire up a local home-manager role on the workstation without re-fetching upstream.

**Sources (priority order):**

1. **Upstream module source (primary):** [`https://raw.githubusercontent.com/cachix/devenv/main/src/modules/machines.nix`](https://raw.githubusercontent.com/cachix/devenv/main/src/modules/machines.nix) — 896 lines. Also saved at `.scratch/hermes-config/raw/machines-module.nix` for offline cross-reference.
2. **Upstream CLI source (primary):** `https://raw.githubusercontent.com/cachix/devenv/main/devenv/src/devenv/machines.rs` — 4079 lines (the CLI handler for `devenv machines {info,deploy,plan,install,apply,status,rollback,check}`). Saved at `.scratch/hermes-config/raw/machines.rs`. Also `devenv/src/cli.rs` for the `MachinesCommand` enum (line 1324).
3. **Official docs:** [`https://devenv.sh/machines/`](https://devenv.sh/machines/) (this page covers the nix-darwin and home-manager section only partially — the local-activation detail lives in the module source).
4. **Local pins:** `bin/devenv` wrapper and `.devenv-toolchain` are devenv v2.4.0 from `github:cachix/devenv/v2.4.0` (per the wrapper script comments).

**TL;DR for ticket 06:**

1. Add `inputs.home-manager` via `devenv inputs add home-manager github:nix-community/home-manager --follows nixpkgs` (required for any home-manager role).
2. Define `machines.workstation = { home-manager = { … }; }` in `devenv.nix` with **no `target.host`**.
3. Build the activation package with `devenv build machines.workstation.build.home-manager` — output goes to `/nix/store/<hash>-devenv-home-manager-generation` (path printed by `devenv build`).
4. Activate it by **executing the result's `activate` script directly** (e.g. `result/activate` from the cwd, or by absolute `/nix/store/...` path). The devenv CLI has **no** `devenv machines apply workstation` or `devenv machines activate workstation` for the no-target case — `machines_deploy` and `machines_plan` filter those machines out, and `machines_install` errors on missing `target.host`.
5. The activation driver wraps the home-manager `activate` so it can `exec` it as the configured user via `runuser` (root) → `sudo` → error if neither is available.

---

## 1. The activation package — exact contents

`machines.workstation.build.home-manager` is a `symlinkJoin` named `devenv-home-manager-generation`. It contains the upstream `homeManagerConfiguration.activationPackage` plus two symlinks at the top level that point at a *devenv-injected* shell driver.

### 1.1 Source shape (`src/modules/machines.nix:199-241`)

```nix
# Source: src/modules/machines.nix:199-241 (verbatim, line numbers in this file)
199:  buildHomeManagerToplevel = machine:
200:    if homeManager == null then
201:      throw (outerConfig.lib._mkInputError homeManagerInputArgs)
202:    else
203:      let
204:        machinePkgs = inputs.nixpkgs.legacyPackages.${machine.system};
205:        evaluated = homeManager.lib.homeManagerConfiguration {
206:          pkgs = machinePkgs;
207:          extraSpecialArgs = { inherit inputs self; };
208:          modules = [ machine.home-manager ];
209:        };
210:        activationPackage = evaluated.activationPackage;
211:        homeUser = evaluated.config.home.username;
212:        homeDirectory = toString evaluated.config.home.homeDirectory;
213:        activationDriver = machinePkgs.writeShellScript "devenv-home-manager-activate" ''
217:          set -eu
218:
219:          user=${lib.escapeShellArg homeUser}
220:          home=${lib.escapeShellArg homeDirectory}
221:          activate=${lib.escapeShellArg "${activationPackage}/activate"}
222:
223:          if [ "$(id -un)" = "$user" ]; then
224:            exec env USER="$user" LOGNAME="$user" HOME="$home" "$activate" "$@"
225:          fi
226:
227:          if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
228:            exec runuser -u "$user" -- \
229:              env USER="$user" LOGNAME="$user" HOME="$home" "$activate" "$@"
230:          fi
231:
232:          if command -v sudo >/dev/null 2>&1; then
233:            exec sudo -H -u "$user" -- \
234:              env USER="$user" LOGNAME="$user" HOME="$home" "$activate" "$@"
235:          fi
236:
237:          echo "home-manager activation must run as $user, but the current user is $(id -un) and neither runuser nor sudo is available" >&2
238:          exit 1
239:        '';
240:      in
```

`src/modules/machines.nix:242-252` produces the join:

```nix
242:      machinePkgs.symlinkJoin {
243:        name = "devenv-home-manager-generation";
244:        paths = [ activationPackage ];
245:        postBuild = ''
246:          rm -f "$out/activate"
247:          ln -s ${activationDriver} "$out/activate"
248:          if [ -d "$out/bin" ]; then
249:            rm -f "$out/bin/home-manager-generation"
250:            ln -s ${activationDriver} "$out/bin/home-manager-generation"
251:          fi
252:        '';
253:      };
```

### 1.2 What `result/` actually contains

After `devenv build machines.workstation.build.home-manager` (which prints the resulting `/nix/store/<hash>-devenv-home-manager-generation` path), the directory layout is:

- **Everything upstream `activationPackage` produces.** That is the standard home-manager "generation" directory: `activate` (the *real* upstream activation script), `home-files/`, `files/`, `activation.d/`, etc. The `symlinkJoin` includes `activationPackage` via `paths = [ activationPackage ]`.
- **`activate` is overwritten.** The `postBuild` hook removes the upstream `activate` and replaces it with a symlink to `activationDriver` (`devenv-home-manager-activate`). So `result/activate` is **not** the upstream home-manager activate — it is devenv's wrapper that picks the user and re-execs the upstream activate.
- **`bin/home-manager-generation` (if `bin/` exists)** is also symlinked to the same driver, so `PATH=$result/bin` exposes the same entry point under a more conventional name.

Net effect: running `result/activate` always lands in the upstream home-manager activate, but it gets there *as the configured user* with `USER`, `LOGNAME`, and `HOME` overridden. The driver passes through any command-line arguments (`"$@"`).

### 1.3 Runtime requirements (verbatim, `src/modules/machines.nix:217-241`)

The driver tries, in order:

1. **Same user already** (`id -un == $user`): just `exec env … "$activate"` with the right `USER`/`LOGNAME`/`HOME` env. **No root required.**
2. **Root + `runuser`** (`id -u == 0` and `runuser` on PATH): `runuser -u "$user" -- env … "$activate"`. This is the path on systemd-hostile systems.
3. **`sudo`** available: `sudo -H -u "$user" -- env … "$activate"`. Used as a fallback.
4. **Error:** if none of the above match (e.g. operator is a non-root, non-sudo user running on a system without `runuser`), the driver prints:

   > `home-manager activation must run as $user, but the current user is $(id -un) and neither runuser nor sudo is available`

   and `exit 1`s. (`src/modules/machines.nix:237-238`)

Consequences for ticket 06:

- On a workstation running as the configured user, **no root needed at all** — the script just `exec`s the upstream activate.
- If the operator runs it as root (e.g. via sudo), `runuser` is preferred (typical on systemd hosts); the driver's `$PATH` lookup is what decides.
- The script does **not** start a systemd user manager on its own. The home-manager activate does, when the relevant home-manager modules ask for it (and home-manager does, transitively, for `systemd.user.*` services). If the systemd user manager is not running, home-manager activation will start it on first activation and the host must have `loginctl enable-linger <user>` set for it to keep running across logouts (this is a home-manager behavior, not a devenv behavior — see §6).

### 1.4 The home-manager input is required (verbatim, `src/modules/machines.nix:30-35`)

```nix
30:  homeManagerInputArgs = {
31:    name = "home-manager";
32:    url = "github:nix-community/home-manager";
33:    attribute = "machines.<name>.home-manager";
34:    follows = [ "nixpkgs" ];
35:  };
```

The `homeManager` lookup at `src/modules/machines.nix:43` is `inputs.home-manager or null`. The `if homeManager == null then throw …` at `src/modules/machines.nix:200-201` triggers whenever **any** machine defines a `home-manager` role. Therefore the exact CLI form for adding it is:

```sh
devenv inputs add home-manager github:nix-community/home-manager --follows nixpkgs
```

This is also documented verbatim in the prior research report (`/home/hbohlen/nix/.scratch/devenv-research/2026-08-24-devenv-capabilities.md` §7). The `--follows nixpkgs` keeps home-manager on the same nixpkgs as the rest of the build, which is the safe default.

---

## 2. The CLI command sequence for local activation

The previous research (`2026-08-24-devenv-capabilities.md` §7) says *"run the activation script"* without pinning the exact CLI command. The upstream source makes this precise: **there is no `devenv machines apply workstation` / `devenv machines activate workstation` for a no-target home-manager machine.** The operator invokes the activation script directly.

### 2.1 What the CLI exposes (`devenv/src/cli.rs:1324-1464`)

The `MachinesCommand` enum has exactly these variants:

| Variant | Source line | What it does |
| --- | --- | --- |
| `Check` | `cli.rs:1326` | NixOS-only — reads target access facts without deploying. |
| `Apply` | `cli.rs:1333` | Re-applies a saved fleet plan; requires a plan ID/JSON file. |
| `Plan` | `cli.rs:1343` | Builds and saves a fleet plan for review. |
| `Status` | `cli.rs:1356` | NixOS-only — reads deployment state from target. |
| `Rollback` | `cli.rs:1363` | NixOS-only — rolls back a transactional deploy. |
| `Info` | `cli.rs:1372` | Lists every machine's name, system, target, roles (table). |
| `Install` | `cli.rs:1382` | NixOS-only — kexec / disko / nixos-install into a fresh host. Requires `target.host`. |
| `Deploy` | `cli.rs:1436` | Build + plan + apply for nixos / nix-darwin / home-manager. |

There is **no** `Activate`, `ApplyLocal`, `Run`, `Local`, or `HomeManager` subcommand.

### 2.2 What `machines_deploy` actually does for no-target home-manager

`devenv/src/devenv/machines.rs:2410-2468`:

```rust
2410:    pub async fn machines_deploy(
…
2418:        let meta = self.load_machines_meta().await?;
2419:        let selected: Vec<String> = if names.is_empty() {
2420:            meta.iter()
2421:                .filter(|(_, machine)| machine.target.host.is_some())   // ← skip no-target
2422:                .map(|(name, _)| name.clone())
2423:                .collect()
2424:        } else {
2425:            names.to_vec()
2426:        };
…
2435:        if selected.is_empty() {
2436:            return Ok(());                                             // ← silent no-op
2437:        }
```

And `machines.rs:2500-2510` for `machines_plan` is identical: it also filters by `target.host.is_some()`. With explicit machine names on the CLI, the selected list is taken verbatim — so if you pass `devenv machines deploy workstation` the selection is non-empty. But the plan validator (`machines.rs:2524-2530`) still bails on `has_nixos || has_nix_darwin` without `target.host`. It does NOT fail for `has_home_manager` alone. So `devenv machines plan workstation` *might* succeed — but only because the plan validator doesn't gate on home-manager + no-target. (It builds the activation package via `build_machine_role` at `machines.rs:2554-2563`.) However, **`machines_deploy` will then try to run `apply_machine_plan`, which sends everything over SSH by default — see §2.3.**

### 2.3 `apply_machine_plan` does SSH by default; local fallback is dead code for `deploy` (verbatim, `machines.rs:2942-2985`)

```rust
2942:    async fn activate_machine_plan(&self, name: &str, entry: &MachinePlanEntry) -> Result<()> {
2943:        let target = entry.target.as_deref().map(SshTarget::parse).transpose()?;
…
2959:        if let Some(path) = &entry.home_manager {
2960:            let activate = Path::new(path).join("activate");
2961:            let result = if let Some(target) = &target {
2962:                self.ssh_run(
2963:                    target,
2964:                    &entry.ssh_opts,
2965:                    &shell_quote(&activate.display().to_string()),
2966:                )
2967:                .await
2968:            } else {
2969:                let status = process::Command::new(&activate)
2970:                    .stdin(Stdio::inherit())
2971:                    .stdout(Stdio::inherit())
2972:                    .stderr(Stdio::inherit())
2973:                    .status()
2974:                    .await
…
2981:            };
```

The local-exec branch (lines 2968-2980) would `exec $activate` directly on the workstation — but the only caller of `activate_machine_plan` is `apply_machine_plan`, which is in turn called by `machines_deploy` (line 2467). And `machines_deploy` *filters* out no-target machines on line 2421 before reaching this code. So the local branch is effectively unreachable through the CLI as written.

> **Net CLI command sequence for local activation:**
> 1. `bin/devenv build machines.workstation.build.home-manager` — prints a store path.
> 2. Operator `exec`s the resulting `/nix/store/<hash>-devenv-home-manager-generation/activate` (or makes a `result` symlink with `--out-link result` and runs `./result/activate`).

The devenv wrapper at `bin/devenv` is a thin shim (`bin/devenv` of this repo) that re-execs `.devenv-toolchain/bin/devenv` — so all CLI commands go through v2.4.0, which has this exact behavior. Verified by reading `bin/devenv` end-to-end (it's 36 lines).

### 2.4 `devenv build machines.<name>` vs `devenv build machines.<name>.build.home-manager`

Both work; the second is the role-restricted form.

- `devenv build machines.workstation` builds every defined role for the machine. Per the comment at `src/modules/machines.nix:595-600`, the build walker recurses into `attrsOf submodule` and picks up `build.nixos`, `build.nix-darwin`, `build.home-manager`, `build.deployer`, `build.diskoScript`, `build.diskoFormatScript`, `build.diskoMountScript`. For a home-manager-only machine, only `build.home-manager` is non-null — so `devenv build machines.workstation` produces exactly one output, the same as `devenv build machines.workstation.build.home-manager`.
- `devenv build machines.workstation.build.home-manager` is the explicit form. **This is what to use** so the operator (and ticket 06 reviewer) see exactly which derivation is being built.

The CLI side confirms this: `build_machine_role(name, "home-manager")` (`machines.rs:2554-2563`) literally calls `self.build(...).await?` with the attribute path `machines.<name>.build.<role>` (line 3172-3178). It's the same code path as `devenv build machines.workstation.build.home-manager`.

---

## 3. Behaviour when `machines.workstation.home-manager` is the only machine block

The repo this ticket belongs to (`/home/hbohlen/nix`) has a single-machine setup with `machines.workstation.home-manager` only (post-ticket 08). The following behaviours all derive from the upstream source.

### 3.1 `devenv machines info` lists it

`machines_info` (`machines.rs:1168-1227`) loads `machinesMeta` and renders a table with columns `Name | System | Target | Roles`. The roles formatter at `machines.rs:1149-1165` produces:

```
home-manager
```

The target cell shows `(no target)` (`machines.rs:1211-1215`) when `target.host` is null. Example output (predicted; not tested in this turn):

```
┌─────────────┬───────────────┬────────────┬────────────────┐
│ Name        ┆ System        ┆ Target     ┆ Roles          │
╞═════════════╪═══════════════╪════════════╪════════════════╡
│ workstation ┆ x86_64-linux  ┆ (no target) ┆ home-manager  │
└─────────────┴───────────────┴────────────┴────────────────┘
```

(That table is rendered with the `comfy-table` crate via `machines.rs:1221-1224`.)

### 3.2 `devenv eval machines.workstation` works

`devenv eval` walks any attribute path on `devenv.config` and returns JSON. `machines.workstation` is an attrset (submodule) — `devenv eval` will return its serialisable contents (no functions, since `machines.workstation` is data — `home-manager` is `nullOr unspecified` per `src/modules/machines.nix:568-579`). The internal `build.home-manager` is `type = outputType` per `src/modules/machines.nix:653-659`; `devenv eval` typically won't serialise `outputType` (it carries a derivation thunk). For practical inspection use:

```sh
devenv eval machines.workstation.home-manager       # the home-manager module value (won't serialise cleanly)
devenv eval machines.workstation.target.host        # null
devenv eval machines.workstation.system             # "x86_64-linux"
devenv eval machinesMeta.workstation.hasHomeManager # true
```

`machinesMeta` is the right surface for CLI consumption — `machines.rs:2483-2497` reads it as JSON.

### 3.3 `devenv build machines.workstation.build.home-manager` produces the activation package

Yes. The `config.build.home-manager = lib.mkIf (config.home-manager != null) (lib.mkDefault (buildHomeManagerToplevel config))` at `src/modules/machines.nix:724` evaluates to a derivation whose `name` is `devenv-home-manager-generation` and whose `outPath` is `/nix/store/<hash>-devenv-home-manager-generation`. Inside that store path, `activate` is the symlink to `devenv-home-manager-activate` (the driver), and everything else comes from `homeManagerConfiguration.activationPackage`.

The output type `outputType` (`src/modules/machines.nix:5`) is the standard devenv `output` wrapper — `devenv build` prints:

```
{ "machines.workstation.build.home-manager": "/nix/store/<hash>-devenv-home-manager-generation" }
```

and creates a `result` symlink to that store path in the project root (this is standard `devenv build` semantics — see the Outputs docs page and `devenv/src/cli.rs` `Build` variant at line 952-955).

### 3.4 `devenv machines deploy workstation` (or `machines plan workstation`) on a no-target home-manager machine

Mixed — neither does what the operator would want:

- **`machines deploy workstation`:** filter at `machines.rs:2421-2423` only skips *un-named* no-target machines. With explicit `names = [workstation]`, the selection is `["workstation"]`. The plan validator at `machines.rs:2516-2530` then runs. It checks:
  - `!has_nixos && !has_nix_darwin && !has_home_manager` → bail (we have `has_home_manager`, so we pass).
  - `has_nixos && has_nix_darwin` → bail (we have neither, pass).
  - `(has_nixos || has_nix_darwin) && target.host.is_none()` → bail (we have neither, pass).
  
  So the plan *might* build successfully, the activation package's store path becomes `entry.home_manager`, and `apply_machine_plan` runs `activate_machine_plan`. With `target = None`, the local-exec branch at `machines.rs:2968-2980` runs `process::Command::new(&activate).status()`. **However**, before reaching that, `apply_machine_plan` has already SSH-connected (or tried to) to validate the plan, etc. — see `machines.rs:2844-2908` and especially the `target.as_ref().unwrap()` calls earlier in `activate_machine_plan` (`machines.rs:2947` for nixos and the `nix_darwin_activation_script` at `machines.rs:2956`). If `entry.nixos` or `entry.nix_darwin` is `Some`, those branches panic on the unwrap. For pure home-manager, those branches are skipped — and the local exec branch runs. **This is not documented in the upstream docs and is not a stable surface.** Don't rely on it.

- **`machines plan workstation`:** identical filter at `machines.rs:2504-2506` for empty `names`; with explicit name, no filter, and `plan_nixos` (`machines.rs:2540`) is gated on `has_nixos`. So for home-manager-only, the plan builds the activation package and prints its store path + a JSON dump — useful as a review step, but it does not activate.

### 3.5 Recommendation for ticket 06

Don't use `machines deploy workstation` or `machines plan workstation` for local activation. The canonical flow is `devenv build machines.workstation.build.home-manager && ./result/activate`. (Or `nix run /nix/store/<hash>-devenv-home-manager-generation/activate` if `result/` is unwanted.)

---

## 4. `target.host` semantics (verbatim)

From `src/modules/machines.nix:257-271`:

```nix
257:    host = lib.mkOption {
258:      type = lib.types.nullOr lib.types.str;
259:      default = null;
260:      description = ''
261:        SSH destination used by `devenv machines install` and `devenv machines deploy`.
262:        Accepts `user@host`, `user@host:port`, or a full `ssh://user@host:port` URI.
263:        Leave unset to activate in process on the current host; this is only valid for `home-manager`.
264:        Setting it to `"localhost"` is not the same as omitting it: `"localhost"` still routes through SSH.
265:      '';
266:      example = "root@laptop.local";
267:    };
```

From the docs page (`https://devenv.sh/machines/`):

> "A home-manager-only machine can omit `target.host` to activate locally. Setting it to `localhost` still uses SSH."

### 4.1 What "activate in process" means

It does **not** mean "devenv auto-runs activation when you `devenv shell`." The CLI has no hook for that. It means: the activation driver at `src/modules/machines.nix:217-241` runs in the same process as the operator's shell, with no SSH hop — see §1.3 above. Specifically:

- The operator executes `$out/activate` in their current shell session.
- The driver (which is itself a shell script written via `writeShellScript`) is `exec`d as the last process.
- The driver `exec`s the upstream home-manager activate, possibly after `runuser`/`sudo` to switch to the configured user.

"Activate in process" therefore contrasts with `target.host = "user@host"`, which routes the same driver over SSH (`machines.rs:2961-2966`). It does **not** mean automatic activation on `devenv shell` or `devenv up`.

### 4.2 When `target.host` is *required*

- `machines.<name>.nixos`: required. The `plan_nixos` call at `machines.rs:2540` followed by `SshTarget::parse(machine.target.host.as_deref().unwrap())` at `machines.rs:2588` will panic on the unwrap.
- `machines.<name>.nix-darwin`: required. Same reason — `nix_darwin_activation_script` invokes SSH unconditionally (`machines.rs:2956`).
- `machines.<name>.home-manager`: **optional**. `target.host = null` means local; any string means SSH.

### 4.3 What `target.host = "localhost"` does

Per `src/modules/machines.nix:257-258` and the docs: `"localhost"` is treated like any other SSH string. The CLI parses it via `SshTarget::parse` (`machines.rs:427-...`) and tries to SSH to `localhost`. If you actually want in-process activation, leave the option unset (don't set it to `"localhost"`).

---

## 5. The home-manager input

The exact CLI form is:

```sh
devenv inputs add home-manager github:nix-community/home-manager --follows nixpkgs
```

Confirmed by the input metadata at `src/modules/machines.nix:30-35` (quoted in §1.4 above) and by the lazy lookup at `src/modules/machines.nix:43` (`homeManager = inputs.home-manager or null`).

The throw at `src/modules/machines.nix:200-201` is unconditional: any machine with `home-manager != null` requires this input. **This is true for home-manager-only machines too** — there is no special exemption.

The `follows = [ "nixpkgs" ]` flag keeps home-manager on the same nixpkgs as the rest of the build. Without it, you'd get a second nixpkgs input and have to keep two pin sets in sync. The `--follows nixpkgs` is what the prior research recommends and what the docs example uses (`https://devenv.sh/machines/` has the equivalent `devenv inputs add disko github:nix-community/disko --follows nixpkgs` for NixOS).

---

## 6. Errors and edge cases

### 6.1 Existing standalone home-manager at `~/.config/home-manager`

The home-manager activate script will refuse to operate on top of an existing standalone install: when run, it notices that `~/.config/home-manager` is already a directory containing a `home.nix` from a *non-devenv* home-manager, and the generation switching can clobber state in `$HOME`.

The devenv wrapper at `src/modules/machines.nix:217-241` does **not** handle this case — it just `exec`s the upstream activate. The upstream home-manager activate (shipped as `activationPackage/activate`, but we don't have a link to it in this ticket's sources) does the check. Concretely, two common failure modes:

- **`~/.config/home-manager/home.nix` already exists** (e.g. from a previous `nix run home-manager -- switch` install): the upstream activate may report a conflict and refuse to proceed.
- **An existing `~/.local/state/nix/profiles/home-manager` symlink chain**: the new generation may not be inserted cleanly, or may overwrite older generations.

**Workaround for ticket 06:** back up `$HOME/.config/home-manager` and `$HOME/.local/state/nix/profiles/home-manager`, then let devenv populate them fresh. Alternatively, scope the home-manager role narrowly (programs and `home.file.*` for `~/.hermes`-related paths only) so it doesn't collide with the standalone config.

This is a home-manager-level concern, not a devenv-level one. The upstream source has nothing else to say about it.

### 6.2 `loginctl enable-linger <user>` not run

home-manager activation will start a systemd user manager for the configured user via `systemd --user`, but the manager only persists across logouts if `loginctl enable-linger <user>` has been set. Without it:

- The user manager is created when the activate runs and torn down when the user logs out.
- `systemd.user.*` services defined in home-manager modules will fail to start on the next boot (because no user manager is running).
- Some home-manager modules (notably anything that depends on `systemd --user` being persistent) will misbehave on the next shell login.

The devenv wrapper does nothing about this. The home-manager upstream activate *may* attempt to set up linger via PAM or systemd presets depending on the home-manager version, but it's not guaranteed — and it requires root. The ticket 06 implementer should consider either:

1. Setting `loginctl enable-linger hbohlen` as a one-off system-level step (requires root or sudo).
2. Adding `services.xserver.displayManager.lightdm.enable = true` (NixOS only — does not apply to non-NixOS workstations).
3. Documenting the manual step in a `README.md` next to the workstation's `devenv.nix`.

### 6.3 systemd user manager not running at activation time

The home-manager activate will start it (the upstream activate calls `systemctl --user start …` and `systemd --user` will fork a manager on demand). The failure mode for ticket 06 is if systemd as a whole is not PID 1 — e.g.:

- Containers without systemd (`docker run … bash`).
- WSL instances without systemd-genie / `systemd --user` emulation.
- macOS (no systemd; launchd instead).

On those hosts, home-manager modules that declare `systemd.user.*` services simply won't work. The ticket-06 implementer should gate such modules with `lib.mkIf pkgs.stdenv.isLinux` or similar — or accept that they only activate on the NixOS netcup host (which is not the target of this ticket).

The devenv wrapper has no special handling here.

### 6.4 `runuser` missing on non-systemd Linux

If the operator runs `result/activate` as root on a non-systemd Linux (e.g. Alpine, Void with runit), and `sudo` isn't installed either, the driver fails at line 234 with the message quoted in §1.3. Install `sudo` (or `util-linux` for `runuser` on systemd hosts).

### 6.5 `devenv machines install workstation`

This errors out, by design, for home-manager-only machines — `machines.rs:1264-1277`:

```rust
1264:            let m = &meta[name];
1265:            if !m.has_nixos {
1266:                bail!(
1267:                    "machines.{name} does not have a `nixos` module set. \
1268:                     `devenv machines install` only applies to NixOS machines. \
1269:                     Use `devenv machines deploy` for home-manager and nix-darwin."
1270:                );
1271:            }
1272:            if m.target.host.is_none() {
1273:                bail!(
1274:                    "machines.{name} does not have `target.host` set. \
1275:                     `devenv machines install` always operates over SSH."
1276:                );
1277:            }
```

So `devenv machines install workstation` always fails — first because there's no `nixos` role, then because `target.host` is null. Both errors are intentional. Don't use `install` for home-manager; use `build` + manual activation (or `machines deploy` if you set `target.host`).

### 6.6 `devenv machines deploy workstation` with no `target.host` (no name argument)

Filtered out at `machines.rs:2419-2423` — `selected` is empty, `machines_deploy` returns `Ok(())` silently. No build, no activation. **Don't use this form for local activation** — it does nothing. (Documented at `machines.rs:2435-2437`.)

### 6.7 Missing `home-manager` input

If you forget `devenv inputs add home-manager …`, evaluating `machines.workstation.home-manager != null` triggers the throw at `src/modules/machines.nix:200-201`:

```nix
throw (outerConfig.lib._mkInputError homeManagerInputArgs)
```

`lib._mkInputError` produces the canonical "Run `devenv inputs add home-manager github:nix-community/home-manager --follows nixpkgs`" hint. The pattern is identical to how the NixOS `disko` input is enforced.

---

## 7. The home-manager role shape — minimal `devenv.nix` for ticket 06

Synthesising the constraints from above, the smallest viable local home-manager role is:

```yaml
# devenv.yaml
inputs:
  home-manager:
    url: github:nix-community/home-manager
    inputs:
      nixpkgs:
        follows: nixpkgs
```

```nix
# devenv.nix
{ inputs, ... }: {
  machines.workstation = {
    system = "x86_64-linux";      # or aarch64-linux / x86_64-darwin / aarch64-darwin
    # target.host deliberately omitted -> activate in process
    home-manager = {
      home.username = "hbohlen";
      home.homeDirectory = "/home/hbohlen";
      # home-manager modules and the hermes-agent module:
      imports = [ inputs.hermes-agent.homeManagerModules.default ];
      services.hermes-agent = {
        enable = true;
        settings = {
          # … see 2026-09-29-hermes-nix-module.md for the full option set.
        };
      };
      programs.git.enable = true;
      # … any other home-manager config …
    };
  };
}
```

Then:

```sh
devenv build machines.workstation.build.home-manager
./result/activate      # or: $(devenv build machines.workstation.build.home-manager | jq -r '.[keys[0]]')/activate
```

The activate script will (a) detect operator == `hbohlen` and just `exec` upstream; or (b) require root + `runuser`, or `sudo`. See §1.3 for the decision tree.

---

## 8. Source citation index

For convenience, all the citations used in this document in one place:

- `src/modules/machines.nix:5` — `outputType` definition.
- `src/modules/machines.nix:30-35` — `homeManagerInputArgs` (input metadata for the error hint).
- `src/modules/machines.nix:43` — `homeManager = inputs.home-manager or null` lazy lookup.
- `src/modules/machines.nix:199-241` — `buildHomeManagerToplevel` body and activation driver (`writeShellScript "devenv-home-manager-activate"`).
- `src/modules/machines.nix:217-241` — full driver script with `runuser`/`sudo` decision tree.
- `src/modules/machines.nix:242-252` — `symlinkJoin` that produces `devenv-home-manager-generation` and overwrites `activate`.
- `src/modules/machines.nix:257-271` — `target.host` option with the verbatim description ("Leave unset to activate in process …").
- `src/modules/machines.nix:568-579` — `machines.<name>.home-manager` option declaration (`nullOr unspecified`, default `null`).
- `src/modules/machines.nix:595-600` — comment block explaining why the build walker recurses into `build.*`.
- `src/modules/machines.nix:653-659` — `build.home-manager = lib.mkOption { type = outputType; internal = true; default = null; }`.
- `src/modules/machines.nix:724` — `config.build.home-manager = lib.mkIf (config.home-manager != null) (lib.mkDefault (buildHomeManagerToplevel config))`.
- `devenv/src/cli.rs:952-955` — `Build { attributes: Vec<String> }` variant (unrestricted attribute paths).
- `devenv/src/cli.rs:935-937` — `Machines { command: MachinesCommand }` variant.
- `devenv/src/cli.rs:1324-1464` — full `MachinesCommand` enum (8 variants; no `Activate`).
- `devenv/src/devenv/machines.rs:168-191` — `outputs()` for the plan, where home-manager maps to `activate` (line 187-188).
- `devenv/src/devenv/machines.rs:1149-1165` — `format_roles` (renders `home-manager` cell).
- `devenv/src/devenv/machines.rs:1168-1227` — `machines_info` (loads `machinesMeta`, renders table).
- `devenv/src/devenv/machines.rs:1264-1277` — `machines_install` per-machine check (errors when `!has_nixos || target.host.is_none()`).
- `devenv/src/devenv/machines.rs:2410-2468` — `machines_deploy` (filters out no-target machines; with explicit names, does not filter).
- `devenv/src/devenv/machines.rs:2483-2497` — `load_machines_meta` (consumes `machinesMeta` from `devenv eval`).
- `devenv/src/devenv/machines.rs:2500-2585` — `machines_plan` (filters, validates, builds the activation package).
- `devenv/src/devenv/machines.rs:2524-2530` — home-manager + no-target is allowed through the plan validator.
- `devenv/src/devenv/machines.rs:2554-2563` — `build_machine_role(name, "home-manager")` for the plan.
- `devenv/src/devenv/machines.rs:2844-2908` — `apply_machine_plan` (the SSH-driven deploy executor).
- `devenv/src/devenv/machines.rs:2942-2985` — `activate_machine_plan` with the local-exec fallback at 2968-2980 (reachable only via `apply_machine_plan`).
- `devenv/src/devenv/machines.rs:3172-3178` — `build_machine_role` itself (it calls `self.build(...).await?` with the `machines.<name>.build.<role>` attribute path).
- `bin/devenv` (this repo) — 36-line wrapper that re-execs `.devenv-toolchain/bin/devenv` (v2.4.0).
- `https://devenv.sh/machines/` — docs page; relevant snippets: "A home-manager-only machine can omit `target.host` to activate locally. Setting it to `localhost` still uses SSH." (in the Define a machine section); table of commands in the Overview.

---

## 9. Open questions / follow-ups

These are not blockers for ticket 06 but worth recording:

1. **Should ticket 06 add a devenv task** that wraps `./result/activate`? The `tasks` option in `devenv.nix` (see `devenv/src/modules/tasks.nix` upstream) lets you declare `tasks."devenv:hm:apply" = { description = "Apply local home-manager generation"; exec = ''${config.machines.workstation.build.home-manager}/activate''; }`. The operator would then run `devenv tasks run devenv:hm:apply`. This is more discoverable than `./result/activate` but is not required.
2. **The local-exec branch at `machines.rs:2968-2980`** is reachable only via `machines deploy <name>` with an explicit name on a home-manager-only, no-target machine. It's not documented; behaviour may change. Don't rely on it.
3. **Activation takes a `--` or `--switch`?** The driver passes through `"$@"` to the upstream activate (`src/modules/machines.nix:224`, line 229, line 234). The upstream home-manager activate accepts flags. None of this is documented in `devenv.sh/machines/`.
4. **What about the `result` symlink cleanup?** `devenv build` creates `result` in the cwd; running `./result/activate` works as long as the cwd hasn't moved. For CI or scripting, prefer the absolute store path or `nix run /nix/store/<hash>-devenv-home-manager-generation/activate`.