# Hermes Agent Nix Module — Reference Document

**Date:** 2026-09-29
**Sources (priority order):**

1. Local clone at `~/.hermes/hermes-agent/` (primary):
   - `~/.hermes/hermes-agent/nix/moduleCommon.nix` (shared option definitions and activation logic)
   - `~/.hermes/hermes-agent/nix/homeManagerModules.nix` (Home Manager module)
   - `~/.hermes/hermes-agent/nix/nixosModules.nix` (NixOS module)
   - `~/.hermes/hermes-agent/nix/configMergeScript.nix` (deep-merge script for `config.yaml`)
   - `~/.hermes/hermes-agent/flake.nix` (flake outputs)
   - `~/.hermes/hermes-agent/hermes_cli/config.py` (managed-mode refusal logic)
   - `~/.hermes/hermes-agent/hermes_cli/managed_scope.py` (distinct `/etc/hermes` overlay layer — NOT Nix managed-mode)
2. Upstream GitHub: `github:NousResearch/hermes-agent` (raw canonical source — used to corroborate local clone).
3. Official docs (Tier 2 / best-effort, used for cross-reference only): `https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup` and the raw markdown source `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/website/docs/getting-started/nix-setup.md`.

**Audience:** An engineer implementing the workstation path (ticket 06). Authoritative enough that they do not have to re-fetch upstream.

---

## 0. How the module is structured

The flake exports two module outputs:

- `nixosModules.default` (`~/.hermes/hermes-agent/nix/nixosModules.nix`)
- `homeManagerModules.default` (`~/.hermes/hermes-agent/nix/homeManagerModules.nix`)

Both modules share almost all of their option declarations, renderers, and state-setup logic. The shared body lives in `~/.hermes/hermes-agent/nix/moduleCommon.nix`, which is a function `{ lib }: { ... }` that the two modules import.

The split is documented verbatim at `~/.hermes/hermes-agent/nix/moduleCommon.nix:1-18`:

> "`services.hermes-agent` is the same option set on both modules. Both modules get their options, their renderers for config.yaml, .env and documents, and their state setup from this file. A NixOS example works on Home Manager without a change. An option added here appears on both modules at once."
>
> "Each module keeps only the parts that belong to its own scope:
>
> - `nixosModules.nix` the service user and group, stateDir, addToSystemPackages, container mode, tmpfiles, system.activationScripts, system systemd units
> - `homeManagerModules.nix` hermesHome, programs.hermes-agent (the CLI and the desktop application), home.activation, systemd.user.services, launchd.agents"

The HM module's own header at `~/.hermes/hermes-agent/nix/homeManagerModules.nix:1-44` further specifies what was *removed* / *changed* / *added* relative to the NixOS module:

> "removed user, group, createUser — Home Manager runs as the user"
> "removed container.* — it needs root and the Docker socket"
> "removed UMask 0007 — that mode shares state with a UNIX group, but this state has one user"
> "changed systemd.services → systemd.user.services or launchd.agents"
> "changed system.activationScripts → home.activation"
> "changed addToSystemPackages → programs.hermes-agent.enable and home.sessionVariables"
> "added programs.hermes-agent the CLI and the desktop application, because Home Manager separates an installation from a daemon"
> "changed stateDir (+ \"/.hermes\") → hermesHome, set directly"

A consequence worth pinning: when the docs say "the same option set," that is exactly what the source confirms — but the NixOS-only set (`user`, `group`, `createUser`, `stateDir`, `addToSystemPackages`, `container.*`) does not exist at all on Home Manager. The HM module does not import it. See `~/.hermes/hermes-agent/nix/homeManagerModules.nix:248-290` (the `options.services.hermes-agent = common.sharedOptions { … } // { hermesHome, installPackage, gateway.enable }` block).

---

## 1. `inputs.hermes-agent.homeManagerModules.default` — what it exposes

From `~/.hermes/hermes-agent/flake.nix:51`:

```nix
imports = [
  ./nix/packages.nix
  ./nix/overlays.nix
  ./nix/nixosModules.nix
  ./nix/homeManagerModules.nix
  ./nix/checks.nix
  ./nix/devShell.nix
];
```

So the flake outputs include:

- `nixosModules.default` — NixOS service module (`~/.hermes/hermes-agent/nix/nixosModules.nix:34`).
- `homeManagerModules.default` — Home Manager module (`~/.hermes/hermes-agent/nix/homeManagerModules.nix:47`).

Plus `packages.<system>.default`, `overlays.default`, `devShells.<system>.default`, and `checks.<system>.*`. The Nix module documentation describes them at `~/.hermes/hermes-agent/website/docs/getting-started/nix-setup.md` and `~/.hermes/hermes-agent/nix/checks.nix`. The relevant input to import from a downstream flake:

```nix
inputs.hermes-agent.url = "github:NousResearch/hermes-agent";
# then
imports = [ hermes-agent.homeManagerModules.default ];
```

The HM module declares two top-level option trees: `services.hermes-agent.*` and `programs.hermes-agent.*` (the latter is the HM-only installation surface).

---

## 2. The full `services.hermes-agent.*` option set

All options are `mkOption`s inside either `common.sharedOptions` (`~/.hermes/hermes-agent/nix/moduleCommon.nix:229-650`) or the per-module extra-options block (HM at `~/.hermes/hermes-agent/nix/homeManagerModules.nix:256-290`, NixOS at `~/.hermes/hermes-agent/nix/nixosModules.nix:262-339`). Per-option type, default, and example follow.

### 2.1 Shared options (identical on HM and NixOS)

| Option | Type | Default | Example | Source |
|---|---|---|---|---|
| `enable` | `bool` (`mkEnableOption "Hermes Agent"`) | `false` | `enable = true;` | `moduleCommon.nix:237` |
| `package` | `package` | `hermes-agent.packages.${system}.default` (HM and NixOS) | `~ same` | `moduleCommon.nix:240` |
| `workingDirectory` | `str` | **HM:** `config.home.homeDirectory`; **NixOS:** `"${stateDir}/workspace"` | — | `moduleCommon.nix:247` |
| `configFile` | `nullOr path` | `null` | `configFile = /etc/hermes/config.yaml;` | `moduleCommon.nix:259` |
| `settings` | `deepConfigType` (deep-merged attrset, `lib.recursiveUpdate`) | `{ }` | `settings.model.default = "anthropic/claude-sonnet-4";` | `moduleCommon.nix:270` |
| `environmentFiles` | `listOf str` | `[ ]` | `environmentFiles = [ config.sops.secrets."hermes/env".path ];` | `moduleCommon.nix:292` |
| `environment` | `attrsOf str` | `{ }` | `environment.HERMES_LOG = "info";` | `moduleCommon.nix:311` |
| `authFile` | `nullOr path` | `null` | `authFile = config.sops.secrets."hermes/auth.json".path;` | `moduleCommon.nix:323` |
| `authFileForceOverwrite` | `bool` | `false` | `authFileForceOverwrite = true;` | `moduleCommon.nix:334` |
| `documents` | `attrsOf (either str path)` | `{ }` | `documents."AGENTS.md" = ./AGENTS.md;` | `moduleCommon.nix:341` |
| `hermesHomeFiles` | `attrsOf (either str path)` | `{ }` | `hermesHomeFiles."SOUL.md" = "You are a helpful AI assistant.";` | `moduleCommon.nix:366` |
| `mcpServers` | `attrsOf mcpServerType` | `{ }` | see §6 below | `moduleCommon.nix:387` |
| `extraPackages` | `listOf package` | `[ ]` | `extraPackages = [ pkgs.pandoc pkgs.imagemagick ];` | `moduleCommon.nix:413` |
| `extraPlugins` | `listOf package` | `[ ]` | `extraPlugins = [ (pkgs.fetchFromGitHub { … }) ];` | `moduleCommon.nix:419` |
| `extraPythonPackages` | `listOf package` | `[ ]` | see example in source | `moduleCommon.nix:440` |
| `extraDependencyGroups` | `listOf str` | `[ ]` | `extraDependencyGroups = [ "hindsight" ];` | `moduleCommon.nix:465` |
| `extraArgs` | `listOf str` | `[ ]` | `extraArgs = [ "--verbose" ];` | `moduleCommon.nix:481` |
| `restart` | `str` | `"always"` | `restart = "on-failure";` | `moduleCommon.nix:487` |
| `restartSec` | `int` | `5` | `restartSec = 10;` | `moduleCommon.nix:493` |
| `backend.mode` | `enum [ "none" "serve" "dashboard" ]` | `"none"` | `backend.mode = "serve";` | `moduleCommon.nix:511` |
| `backend.host` | `str` | `"127.0.0.1"` | `backend.host = "100.100.100.10";` | `moduleCommon.nix:532` |
| `backend.waitFor` | `nullOr enum [ "hostname" "interface" ]` | `null` | `backend.waitFor = "hostname";` | `moduleCommon.nix:550` |
| `backend.interfaceName` | `nullOr str` | `null` | `backend.interfaceName = "tailscale0";` | `moduleCommon.nix:587` |
| `backend.waitTimeout` | `positive int` | `120` | — | `moduleCommon.nix:599` |
| `backend.port` | `port` | `9119` | — | `moduleCommon.nix:611` |
| `backend.extraArgs` | `listOf str` | `[ ]` | — | `moduleCommon.nix:617` |
| `backend.sessionTokenFile` | `nullOr str` | `null` | `backend.sessionTokenFile = config.sops.secrets."hermes/desktop-token".path;` | `moduleCommon.nix:623` |

### 2.2 NixOS-only options (HM does not have these)

| Option | Type | Default | Example | Source |
|---|---|---|---|---|
| `user` | `str` | `"hermes"` | `user = "alice";` | `nixosModules.nix:263` |
| `group` | `str` | `"hermes"` | — | `nixosModules.nix:269` |
| `createUser` | `bool` | `true` | `createUser = false;` | `nixosModules.nix:275` |
| `stateDir` | `str` | `"/var/lib/hermes"` | `stateDir = "/opt/hermes";` | `nixosModules.nix:282` |
| `addToSystemPackages` | `bool` | `false` | `addToSystemPackages = true;` | `nixosModules.nix:288` |
| `container.enable` | `bool` (`mkEnableOption`) | `false` | — | `nixosModules.nix:300` |
| `container.backend` | `enum [ "docker" "podman" ]` | `"docker"` | `container.backend = "podman";` | `nixosModules.nix:302` |
| `container.extraVolumes` | `listOf str` | `[ ]` | `container.extraVolumes = [ "/data:/data:rw" ];` | `nixosModules.nix:311` |
| `container.extraOptions` | `listOf str` | `[ ]` | `container.extraOptions = [ "--gpus" "all" ];` | `nixosModules.nix:318` |
| `container.image` | `str` | `"ubuntu:24.04"` | — | `nixosModules.nix:324` |
| `container.hostUsers` | `listOf str` | `[ ]` | `container.hostUsers = [ "alice" ];` | `nixosModules.nix:330` |

### 2.3 Home Manager-only options (NixOS does not have these)

| Option | Type | Default | Example | Source |
|---|---|---|---|---|
| `hermesHome` | `str` | `"${config.home.homeDirectory}/.hermes"` | `hermesHome = "/home/alice/.hermes-work";` | `homeManagerModules.nix:256` |
| `installPackage` | `nullOr bool` (deprecated; **removed**) | `null` (always errors when set) | — | `homeManagerModules.nix:280` |
| `gateway.enable` | `bool` (`mkEnableOption "the messaging gateway service (Telegram, Discord, Slack, ...)"`) | `false` | `gateway.enable = true;` | `homeManagerModules.nix:289` |

### 2.4 The HM `programs.hermes-agent` subtree (a separate option tree, not under `services`)

| Option | Type | Default | Example | Source |
|---|---|---|---|---|
| `programs.hermes-agent.enable` | `bool` (`mkEnableOption`) | `false` | `programs.hermes-agent.enable = true;` | `homeManagerModules.nix:191` |
| `programs.hermes-agent.package` | `package` | `services.hermes-agent.package` (with extraPythonPackages / extraDependencyGroups applied) | — | `homeManagerModules.nix:199` |
| `programs.hermes-agent.desktop.enable` | `bool` (`mkEnableOption`) | `false` | `programs.hermes-agent.desktop.enable = true;` | `homeManagerModules.nix:215` |
| `programs.hermes-agent.desktop.package` | `package` | `package.hermesDesktop` | — | `homeManagerModules.nix:230` |

---

## 3. The `settings` attribute — how it becomes `config.yaml`

### 3.1 The render pipeline

`settings` is declared with a custom `deepConfigType` defined in `~/.hermes/hermes-agent/nix/moduleCommon.nix:31-36`:

```nix
deepConfigType = types.mkOptionType {
  name = "hermes-config-attrs";
  description = "Hermes YAML config (attrset), merged deeply via lib.recursiveUpdate.";
  check = builtins.isAttrs;
  merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (d: d.value) defs);
};
```

So when more than one module sets `settings = { … }`, they are deep-merged at Nix evaluation time via `lib.recursiveUpdate`. The Nix module's own description (`moduleCommon.nix:270-281`) documents the runtime side too:

> "The merge into the config.yaml on disk is also a deep merge. These keys replace the keys on disk. The module keeps all other keys, which includes the keys that `hermes config set` and the settings panes of the TUI and the desktop app write at runtime."

### 3.2 The JSON-to-YAML render

The Nix-side render is in `~/.hermes/hermes-agent/nix/moduleCommon.nix:688-703`:

```nix
mkConfigFiles =
  { pkgs, cfg, workingDirectory }:
  let
    generated = pkgs.writeText "hermes-config.yaml" (
      builtins.toJSON (lib.recursiveUpdate { terminal.cwd = workingDirectory; } cfg.settings)
    );
  in
  {
    inherit generated;
    effective = if cfg.configFile != null then cfg.configFile else generated;
    mergeScript = pkgs.callPackage ./configMergeScript.nix { };
  };
```

So the **first** stage is `pkgs.writeText` (NOT `pkgs.formats.yaml` — the module generates JSON, not YAML directly, by `builtins.toJSON`). JSON is a subset of YAML; this is the render pipeline trick. The on-disk file ends up as YAML because the merge script (`~/.hermes/hermes-agent/nix/configMergeScript.nix`) does the actual disk write using PyYAML.

### 3.3 The merge script

`~/.hermes/hermes-agent/nix/configMergeScript.nix:6-33` produces a Python script that:

1. Loads the Nix-generated JSON (`sys.argv[1]`).
2. Loads the existing `config.yaml` (`sys.argv[2]`) with `yaml.safe_load`.
3. `deep_merge(existing, nix)` — existing wins on missing keys, Nix wins on present keys, and dicts are recursively merged.
4. Writes the result back with `yaml.dump(..., default_flow_style=False, sort_keys=False)`.

The script is invoked from `~/.hermes/hermes-agent/nix/moduleCommon.nix:846-854`:

```nix
${if cfg.configFile != null then
  "${inst} -m ${modes.config} -D ${configFiles.effective} ${hermesHome}/config.yaml"
else
  ''
    ${run}${configFiles.mergeScript} ${configFiles.generated} ${hermesHome}/config.yaml
    ${run}chmod ${modes.config} ${hermesHome}/config.yaml
  ''
}
```

So at runtime, the file written to `$HERMES_HOME/config.yaml` is YAML (PyYAML output), with the Nix-declared keys deep-merged on top of whatever the agent or a manual edit previously wrote. The merge script is built with `python3.withPackages (ps: [ ps.pyyaml ])`.

### 3.4 Where the file lands

- HM: `~/.hermes/config.yaml` — by default `hermesHome = "${config.home.homeDirectory}/.hermes"` (`homeManagerModules.nix:258`).
- NixOS: `${cfg.stateDir}/.hermes/config.yaml` — `${stateDir}` is `/var/lib/hermes` by default; `hermesHome` is derived in `nixosModules.nix:50` as `${cfg.stateDir}/.hermes`.

### 3.5 `terminal.cwd` injection

The module always injects `terminal.cwd = workingDirectory` into `cfg.settings` before rendering (`moduleCommon.nix:696` — `lib.recursiveUpdate { terminal.cwd = workingDirectory; } cfg.settings`). The comment explains:

> "YAML contains JSON, so the output of toJSON is a correct config.yaml. terminal.cwd replaces the old MESSAGING_CWD environment variable. The order of the recursiveUpdate lets an explicit settings.terminal.cwd replace the default value."

So `services.hermes-agent.settings.model.default = "x"` produces a `config.yaml` with at least:

```yaml
{
  "terminal": { "cwd": "<workingDirectory>" },
  "model": { "default": "x" }
}
```

…until the agent (or `hermes config set …`) saves runtime keys. On the next activation, the merge script preserves those runtime keys unless they overlap with a Nix-declared key.

---

## 4. `environmentFiles` and `authFile` — verbatim

### 4.1 `environmentFiles` — what is done with the contents

Declared at `~/.hermes/hermes-agent/nix/moduleCommon.nix:292-309`. Verbatim option text:

> "The paths to environment files that contain secrets, for example API keys and tokens. Activation adds the contents of these files to $HERMES_HOME/.env. Hermes reads that file at each start, with load_hermes_dotenv().
>
> Each activation writes .env again from the start. Thus a secret file cannot go into .env two times."

Two important consequences pinned in source comments:

1. **Type is `listOf str`, not `listOf path`** (`moduleCommon.nix:293-296`):
   > "The type is `str` and not `path` for a reason. A Nix path literal copies the secret into the Nix store, which all users can read. Use a runtime path from sops-nix or agenix instead, for example `config.sops.secrets."x".path`."
2. **Default = `[]` (empty list).** A given file path is *not* the store path of the secret; it is the live `/var/lib/hermes/.env.sops` path that the secrets manager writes at activation time.

How the contents are merged into `.env` — `mkEnvScript` at `moduleCommon.nix:734-758`:

```nix
pkgs.writeShellScript "hermes-env-merge" ''
  set -eu

  dest="$1"
  mode="$2"
  shift 2

  install -m "$mode" ${base} "$dest"
  for file in "$@"; do
    if [ -r "$file" ]; then
      printf '\n' >> "$dest"
      cat "$file" >> "$dest"
    else
      echo "hermes-agent: WARNING cannot read environmentFile $file" >&2
    fi
  done
''
```

The base is a `writeText` of all `cfg.environment` (non-secret vars). Each `environmentFiles` path is then `cat`'d and appended. So secrets are concatenated into a single `.env` at `$HERMES_HOME/.env`. Default file modes (`moduleCommon.nix:860-863` and the per-module `modes` block):

- HM: `env = "0600"` (`homeManagerModules.nix:387`)
- NixOS: `env = "0640"` (`nixosModules.nix:492`)

### 4.2 `authFile` — first-write-wins, where it lands

Declared at `~/.hermes/hermes-agent/nix/moduleCommon.nix:323-332`. Verbatim option text:

> "The path to a file that gives the first contents of auth.json, the OAuth credentials. The module copies the file only when auth.json does not exist. Thus a token that Hermes refreshes at runtime stays after an activation."

Default is `null`. The activation logic is at `moduleCommon.nix:865-874`:

```nix
${lib.optionalString (cfg.authFile != null) (
  if cfg.authFileForceOverwrite then
    "${inst} -m ${modes.auth} ${cfg.authFile} ${hermesHome}/auth.json"
  else
    ''
      if [ ! -e ${hermesHome}/auth.json ]; then
        ${inst} -m ${modes.auth} ${cfg.authFile} ${hermesHome}/auth.json
      fi
    ''
)}
```

Two answers:

- **First-write-wins (default):** the file at `$HERMES_HOME/auth.json` is created from `cfg.authFile` only if no file exists. Subsequent activations skip the copy. Runtime OAuth refreshes (Discord, etc.) survive rebuilds.
- **Always-overwrite:** when `authFileForceOverwrite = true`, the file is unconditionally re-installed on every activation.

Default mode for `auth.json`: `0600` on both modules (`homeManagerModules.nix:389`; `nixosModules.nix:493`). Where:

- NixOS: `${stateDir}/.hermes/auth.json` → default `/var/lib/hermes/.hermes/auth.json`.
- HM: `${hermesHome}/auth.json` → default `~/.hermes/auth.json`.

Note that `authFile` is a `path`-typed value (`moduleCommon.nix:324` — `types.nullOr types.path`), not `str`. Unlike `environmentFiles`, this one copies into the store if you give a Nix-store path literal. The docs and source both show sops/agenix syntax:

> `authFile = config.sops.secrets."hermes/auth.json".path;` — `~/.hermes/hermes-agent/website/docs/getting-started/nix-setup.md` (OAuth section).

---

## 5. `stateDir` semantics — NixOS vs Home Manager

### 5.1 NixOS

- **Default:** `/var/lib/hermes` (`~/.hermes/hermes-agent/nix/nixosModules.nix:284`).
- **`hermesHome` is derived:** `"${cfg.stateDir}/.hermes"` (`nixosModules.nix:50`).
- The module wires systemd tmpfiles at `nixosModules.nix:444-451` (mode `2770 hermes:hermes`) for `stateDir`, `hermesHome`, `stateDir/home`, `workingDirectory`, and the subdirs.
- Activation script (`nixosModules.nix:462-467`) creates the directories and sets `chown hermes:hermes`, `chmod 2770` before the state-setup script copies state files in.

### 5.2 Home Manager

- **Default:** `"${config.home.homeDirectory}/.hermes"` (`~/.hermes/hermes-agent/nix/homeManagerModules.nix:258`).
- `hermesHome` is an **option** on HM (not derived). The HM module sets HERMES_HOME in `home.sessionVariables.HERMES_HOME = cfg.hermesHome;` (`homeManagerModules.nix:300`) and passes it to the activation via `common.mkStateScript` (`homeManagerModules.nix:380`).
- The activation creates the directory explicitly. `mkStateScript` at `moduleCommon.nix:828-840`:

  ```nix
  ${run}mkdir -p ${
    lib.escapeShellArgs (
      [ hermesHome, workingDirectory ]
      ++ map (d: "${hermesHome}/${d}") stateDirs
    )
  }
  ```

  …where `stateDirs = common.stateSubdirs` (`moduleCommon.nix:1135-1141`) is `["cron" "sessions" "logs" "memories" "plugins"]`.

- Mode is `0600` for config/env/managed/auth/document (`homeManagerModules.nix:385-390`); no group-mode sharing because "this state has one user" (`homeManagerModules.nix:144-146`). Systemd unit `UMask = "0077"` (`homeManagerModules.nix:146`).
- **Does it create the directory, or expect it pre-existing?** The activation creates it; the docs do not have to set it. If `hermesHome` is changed mid-life, the activation will `mkdir -p` the new path and `install -D` the files there, but existing state at the old path is **not** migrated by the module. The HM header comment at `homeManagerModules.nix:25` says:

  > "changed stateDir (+ \"/.hermes\") → hermesHome, set directly"

  …and the option description (`homeManagerModules.nix:266-268`):

  > "The value of HERMES_HOME. This state directory holds config.yaml, .env, auth.json, the sessions, the skills, the memory and the cron jobs.
  >
  > The NixOS module takes a `stateDir` and adds `/.hermes` to it. This module sets HERMES_HOME directly. Thus an existing ~/.hermes continues to work, and you can give the directory any name."

### 5.3 What the docs say about HM (contradiction check)

The official docs (`website/docs/getting-started/nix-setup.md` "Customization Cheatsheet") only mention it on the NixOS row:

> | Change state directory | `stateDir` | `"/opt/hermes"` |

HM has no `stateDir` — only `hermesHome`. **The docs do not list `hermesHome`** in the cheatsheet. **Source-of-truth:** use `services.hermes-agent.hermesHome` on Home Manager.

---

## 6. Option shapes for `extraArgs`, `extraPackages`, `extraPlugins`, `extraDependencyGroups`, `mcpServers`, `documents`, `hermesHomeFiles`, `backend`, `container`

### 6.1 `extraArgs` — `listOf str`

`~/.hermes/hermes-agent/nix/moduleCommon.nix:481-485`:

> "Extra command-line arguments for `hermes gateway`."

Verbatim:

```nix
extraArgs = mkOption {
  type = types.listOf types.str;
  default = [ ];
  description = "Extra command-line arguments for `hermes gateway`.";
};
```

Example: `extraArgs = [ "--verbose" ];`. Note that `backend.extraArgs` exists too and is its own option (`moduleCommon.nix:617-621`).

### 6.2 `extraPackages` — `listOf package`

`~/.hermes/hermes-agent/nix/moduleCommon.nix:413-415`:

```nix
extraPackages = mkOption {
  type = types.listOf types.package;
  default = [ ];
  description = "More packages on the PATH of the agent. The agent can run these tools.";
};
```

Example: `extraPackages = [ pkgs.pandoc pkgs.imagemagick ];`. On NixOS, these go on the unit's PATH **and** into the hermes user's per-user profile so the login shell snapshot sees them (`nixosModules.nix:420-425`). On HM, they are added to `home.packages` only when `programs.hermes-agent.enable` is true (`homeManagerModules.nix:360-362`).

### 6.3 `extraPlugins` — `listOf package` (directory plugins)

`~/.hermes/hermes-agent/nix/moduleCommon.nix:419-438`:

```nix
extraPlugins = mkOption {
  type = types.listOf types.package;
  default = [ ];
  description = ''
    Directory-based plugin packages to symlink into the hermes plugins
    directory. Each package must contain a plugin.yaml and __init__.py
    at its root. Hermes discovers these automatically on startup.
  '';
  example = literalExpression ''
    [
      (pkgs.fetchFromGitHub {
        owner = "stephenschoettler";
        repo = "hermes-lcm";
        name = "hermes-lcm";
        rev = "v0.7.0";
        hash = "sha256-...";
      })
    ]
  '';
};
```

Activation logic at `moduleCommon.nix:879-889`:

```nix
${run}find ${hermesHome}/plugins -maxdepth 1 -type l -name 'nix-managed-*' -delete 2>/dev/null || true
${lib.concatMapStringsSep "\n" (plugin: ''
  if [ ! -f ${plugin}/plugin.yaml ]; then
    echo "hermes-agent: ERROR extraPlugins entry '${plugin}' has no plugin.yaml" >&2
    exit 1
  fi
  ${run}ln -sfn ${plugin} ${hermesHome}/plugins/nix-managed-${lib.getName plugin}
'') cfg.extraPlugins}
```

So each entry is symlinked as `${hermesHome}/plugins/nix-managed-<name>`. Removing a plugin from the option list removes the symlink on the next activation.

There is also `extraPythonPackages` (`listOf package`) for entry-point plugins that register via `hermes_agent.plugins` (`moduleCommon.nix:440-463`). The two are documented at `website/docs/getting-started/nix-setup.md` "Plugins" section.

### 6.4 `extraDependencyGroups` — `listOf str`

`~/.hermes/hermes-agent/nix/moduleCommon.nix:465-478`:

```nix
extraDependencyGroups = mkOption {
  type = types.listOf types.str;
  default = [ ];
  description = ''
    Additional pyproject.toml optional-dependency groups to include in
    the sealed Python venv. These are resolved by uv alongside core
    dependencies — no PYTHONPATH patching or collision risk.
    ...
  '';
  example = [ "hindsight" ];
};
```

Example use case from the docs: `extraDependencyGroups = [ "messaging" ];` enables Discord / Telegram / Slack.

### 6.5 `mcpServers` — `attrsOf mcpServerType`

The submodule is in `~/.hermes/hermes-agent/nix/moduleCommon.nix:39-179`. Schema:

| Field | Type | Default |
|---|---|---|
| `command` | `nullOr str` | `null` |
| `args` | `listOf str` | `[ ]` |
| `env` | `attrsOf str` | `{ }` |
| `url` | `nullOr str` | `null` |
| `headers` | `attrsOf str` | `{ }` |
| `auth` | `nullOr enum [ "oauth" ]` | `null` |
| `enabled` | `bool` | `true` |
| `timeout` | `nullOr int` | `null` (default 120s) |
| `connect_timeout` | `nullOr int` | `null` (default 60s) |
| `tools` | `nullOr submodule { include; exclude }` | `null` |
| `sampling` | `nullOr submodule { enabled, model, max_tokens_cap, timeout, max_rpm, max_tool_rounds, allowed_models, log_level }` | `null` |

Canonical example from `moduleCommon.nix:394-409`:

```nix
{
  filesystem = {
    command = "npx";
    args = [ "-y" "@modelcontextprotocol/server-filesystem" "/home/user" ];
  };
  remote-api = {
    url = "http://my-server:8080/v0/mcp";
    headers = { Authorization = "Bearer ..."; };
  };
  remote-oauth = {
    url = "https://mcp.example.com/mcp";
    auth = "oauth";
  };
}
```

`mcpServers` is then merged into `settings.mcp_servers` by `common.mcpServersToConfig cfg.mcpServers` (`homeManagerModules.nix:330`, `nixosModules.nix:348`). The conversion strips `null` and empty-list fields (`moduleCommon.nix:182-222`).

### 6.6 `documents` — `attrsOf (either str path)`

`~/.hermes/hermes-agent/nix/moduleCommon.nix:341-364`. Each key is a path relative to `workingDirectory`; the module `mkdir -p`s subdirectories. Values are strings or paths. Example:

```nix
documents = {
  "AGENTS.md" = ./AGENTS.md;
  "notes/oncall.md" = "Page #infra before restarting anything.";
};
```

Install command from `moduleCommon.nix:819-825`:

```nix
installDocuments = tree: root: docs:
  lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: _value: "${inst} -m ${modes.document} -D ${tree}/${name} ${root}/${name}"
    ) docs
  );
```

**Assertion:** `documents != { }` requires that `workingDirectory` was set explicitly (not at its default). Source: `moduleCommon.nix:1077-1103` — `workspaceFilesAssertions`. The error message references the rule:

> "The files go into workingDirectory. The default of that option is different on each module, so an unset default puts the files in a directory that you did not select. Set the directory: `services.hermes-agent.workingDirectory = "/path/you/want";`."

### 6.7 `hermesHomeFiles` — `attrsOf (either str path)`

`~/.hermes/hermes-agent/nix/moduleCommon.nix:366-384`. Same type as `documents`, but files land under `$HERMES_HOME` (not `workingDirectory`). `SOUL.md` and `memories/` must be installed here for the agent to load them as identity / memory. Verbatim from the option text:

> "Hermes reads SOUL.md and the memory files from HERMES_HOME and not from the working directory. Declare those files here, or Hermes does not load them."

Example:

```nix
hermesHomeFiles = {
  "SOUL.md" = "You are a helpful AI assistant.";
  "memories/USER.md" = ./USER.md;
};
```

### 6.8 `backend` — submodule

The full submodule is `moduleCommon.nix:510-649`. Schema (already in §2.1). The backend runs `hermes serve` (no UI) or `hermes dashboard` (web UI on the same port) on `cfg.backend.host:cfg.backend.port`. Both give `/api/ws` and `/api/pty` sockets that Hermes Desktop connects to.

Important caveats from the source comments:

1. `backend.mode != "none"` requires a non-loopback host to start the auth gate (or else any localhost client can connect). Verbatim from `moduleCommon.nix:536-547`:

   > "An address other than loopback starts the authentication gate of the dashboard. You must then configure credentials, or a client cannot connect. The server also refuses each request with a Host header that is different from the address that the server bound to. This is a defence against DNS rebinding. Bind to the name or the address that your clients use."

2. `backend.waitFor = "hostname" | "interface"` is a poll (not a dependency), since a systemd user unit cannot order itself after a system unit. `waitTimeout = 120` seconds, then the unit fails.

3. On NixOS, `backend.mode != "none"` is mutually exclusive with `container.enable = true`. Source: `nixosModules.nix:410-412`:

   > "Container mode runs one command in one container. A second process needs its own container and its own ports. This module does not do that."

   ```nix
   assertion = !(cfg.container.enable && cfg.backend.mode != "none");
   message = "Services.hermes-agent: backend.mode is not supported together with container.enable — the container runs the gateway only.";
   ```

4. On Darwin HM, only `"hostname"` is allowed; `"interface"` is Linux-only (`homeManagerModules.nix:351-353`).

### 6.9 `container` — NixOS-only submodule

`~/.hermes/hermes-agent/nix/nixosModules.nix:299-339`. Already in §2.2. Schema:

```nix
container = {
  enable       = bool;            # default false
  backend      = enum ["docker","podman"];  # default "docker"
  extraVolumes = listOf str;      # default []
  extraOptions = listOf str;      # default []
  image        = str;             # default "ubuntu:24.04"
  hostUsers    = listOf str;      # default []
};
```

`container.enable = true` triggers a substantial different code path (`nixosModules.nix:636-711`): the systemd service is replaced with a `docker create` / `start` script. The container identity hash (`nixosModules.nix:182-189`) covers `image`, `extraVolumes`, and `extraOptions`; only those changes trigger container recreation.

---

## 7. Managed-mode trigger — verbatim

### 7.1 The `HERMES_MANAGED` environment variable

Set from the NixOS service environment at `~/.hermes/hermes-agent/nix/nixosModules.nix:236-239`:

```nix
commonUnitEnvironment = {
  HOME = cfg.stateDir;
}
  // common.processEnvironment { inherit hermesHome; };
```

`processEnvironment` is in `~/.hermes/hermes-agent/nix/moduleCommon.nix:1046-1054`:

```nix
processEnvironment =
  { hermesHome, managedSystem ? "true" }:
  {
    HERMES_HOME = hermesHome;
    HERMES_MANAGED = managedSystem;
  };
```

So `HERMES_MANAGED` is always present in the unit environment. Each module picks its own `managedSystem` value:

- **NixOS:** default `"true"` (inherited from the function default) — note: the NixOS activation script defaults to `"nixos"` when writing `.managed` (see §7.2), but the systemd `HERMES_MANAGED` env var is also set via the unit; the CLI resolves both signals (env var first, then file).
- **Home Manager:** `managedSystem = "home-manager"` (`homeManagerModules.nix:70`). Verbatim comment above the assignment (`homeManagerModules.nix:68-69`):

  > "The CLI reads this value and names it when it refuses a configuration change."

### 7.2 The `.managed` marker file write

`~/.hermes/hermes-agent/nix/moduleCommon.nix:856-858`:

```nix
# The managed-mode marker. It makes an interactive shell also refuse to
# change the configuration that Nix owns.
${inst} -m ${modes.managed} ${pkgs.writeText "hermes-managed" managedSystem} ${hermesHome}/.managed
```

So `$HERMES_HOME/.managed` is the literal text `managedSystem`:

- HM: `"home-manager"` (`homeManagerModules.nix:382`).
- NixOS: `"nixos"` (`nixosModules.nix:490` — `managedSystem ? "nixos"` default in `mkStateScript`).

Mode `0600` on HM (`homeManagerModules.nix:387`), `0644` on NixOS (`nixosModules.nix:492`).

### 7.3 The CLI refusal logic

`~/.hermes/hermes-agent/hermes_cli/config.py:271-291`:

```python
def get_managed_system() -> Optional[str]:
    """Return the package manager owning this install, if any.
    Signals: HERMES_MANAGED env var (systemd service) or a ``.managed`` marker file in
    HERMES_HOME (NixOS activation script — interactive shells don't see the service env)."""
    marker = os.getenv("HERMES_MANAGED", "").strip().lower() or None
    managed_marker = get_hermes_home() / ".managed"
    if marker is None and managed_marker.exists():
        try:
            marker = managed_marker.read_text(encoding="utf-8", errors="replace").strip().lower()
        except OSError:
            marker = ""
    if marker is None or marker in _IGNORED_MANAGED_VALUES or marker in _MANAGED_FALSE_VALUES:
        return None
    if marker == "" or marker in _MANAGED_TRUE_VALUES:
        return _LEGACY_MANAGED_SYSTEM
    return marker


def is_managed() -> bool:
    """Check if Hermes is running in package-manager-managed mode."""
    return get_managed_system() is not None
```

Where:

- `_MANAGED_TRUE_VALUES = ("true", "1", "yes")` (`config.py:256`)
- `_NIX_MANAGED_SYSTEMS = {"nixos", "home-manager"}` (`config.py:257`)
- `_LEGACY_MANAGED_SYSTEM = "nixos"` (`config.py:259`)
- `_IGNORED_MANAGED_VALUES = frozenset({"brew", "homebrew"})` (`config.py:265`)
- `_MANAGED_FALSE_VALUES = frozenset({"false", "0", "no", "off"})` (`config.py:268`)

So the env var `HERMES_MANAGED` takes precedence; the `.managed` file is the fallback for processes (interactive shells) that don't inherit the service env.

### 7.4 The exact CLI refusal text

`~/.hermes/hermes-agent/hermes_cli/config.py:440-450`:

```python
def format_managed_message(action: str = "modify this Hermes installation") -> str:
    """Build a user-facing error for managed installs."""
    managed_system = get_managed_system() or "a package manager"
    return (
        f"Cannot {action}: this Hermes installation is managed by {managed_system}.\n"
        "Use your package manager to upgrade or reinstall Hermes.")


def managed_error(action: str = "modify configuration"):
    """Print user-friendly error for managed mode."""
    print(format_managed_message(action), file=sys.stderr)
```

So a `hermes config set …` invocation under NixOS managed mode prints (to stderr):

```
Cannot modify configuration: this Hermes installation is managed by nixos.
Use your package manager to upgrade or reinstall Hermes.
```

…where the action verb varies by call site (`save_env_value` uses `f"{action} {key}"`, etc. — see `config.py:2615`, `3033`, `3529`, `3649`).

### 7.5 The Nix-update hint when on Nix managed mode

`~/.hermes/hermes-agent/hermes_cli/config.py:296-299`:

```python
_NIX_UPDATE_MSG = (
    "Update Hermes through the Nix source that installed it "
    "(e.g. nix profile upgrade, or update your flake input and rebuild with nixos-rebuild or home-manager switch)"
)
```

Triggered when the install method is one of `_NIX_MANAGED_SYSTEMS = {"nixos", "home-manager"}` (`config.py:302-304`).

### 7.6 Distinction: the `/etc/hermes` overlay layer

`~/.hermes/hermes-agent/hermes_cli/managed_scope.py:1-169` is a **different** mechanism, called the "managed scope." It uses `HERMES_MANAGED_DIR` env var (default `/etc/hermes`) and lets an admin overlay only **specific** keys onto `config.yaml` / `.env`. It is not what the Nix module sets up — the Nix module sets `HERMES_MANAGED` (the coarse package-manager write-lock), not `HERMES_MANAGED_DIR`. The Nix module writes nothing under `/etc/hermes`.

---

## 8. The full path of `services.hermes-agent.settings` rendering

When `services.hermes-agent.settings.model.default = "x"` is set on Home Manager:

1. Nix evaluates `deepConfigType.merge` (`moduleCommon.nix:35`), `lib.foldl' lib.recursiveUpdate` over all `settings` definitions.
2. `mkConfigFiles` (`moduleCommon.nix:688-703`) creates a `pkgs.writeText "hermes-config.yaml"` containing `builtins.toJSON (lib.recursiveUpdate { terminal.cwd = workingDirectory; } cfg.settings)`. This is JSON, but valid YAML.
3. The HM activation (`homeManagerModules.nix:370-392`) runs `common.mkStateScript` after `writeBoundary` and `linkGeneration`. The script invokes `configFiles.mergeScript ${configFiles.generated} ${hermesHome}/config.yaml` (`moduleCommon.nix:851`).
4. The merge script (`configMergeScript.nix`) reads the JSON, reads the existing `~/.hermes/config.yaml`, `deep_merge(existing, nix)`, then `yaml.dump(merged, f, default_flow_style=False, sort_keys=False)` writes back.
5. Result: `~/.hermes/config.yaml` (HM) or `/var/lib/hermes/.hermes/config.yaml` (NixOS), YAML formatted by PyYAML, `sort_keys=False` (preserves the order: terminal.cwd first, then user-declared keys in the order they appear in `cfg.settings`).

The exact on-disk path:

- HM: `cfg.hermesHome + "/config.yaml"`. Default: `${config.home.homeDirectory}/.hermes/config.yaml` → `~/.hermes/config.yaml`.
- NixOS: `${cfg.stateDir}/.hermes/config.yaml`. Default: `/var/lib/hermes/.hermes/config.yaml`.

---

## 9. Source-only options not in the docs

The following options exist in the module but are not listed in the official "Options Reference" table at `~/.hermes/hermes-agent/website/docs/getting-started/nix-setup.md`:

- `backend.waitFor`, `backend.interfaceName`, `backend.waitTimeout`, `backend.sessionTokenFile` — the docs only mention `mode`, `host`, `port`, `extraArgs`.
- `extraPythonPackages` — only mentioned in the "Plugins" prose, not in the cheatsheet table.
- `restart`, `restartSec` — absent from the docs cheatsheet.
- `authFileForceOverwrite` — mentioned in the OAuth example but not tabulated.
- `hermesHome` (HM) — absent from the docs entirely; only `stateDir` is listed (NixOS-only).
- `gateway.enable` (HM) — absent from the docs.
- `programs.hermes-agent.{enable, package, desktop.enable, desktop.package}` (HM) — present in the docs as a prose section, but not in the option-type tables.
- The hardcoded module behaviors: HM `UMask = "0077"`, NixOS `UMask = "0007"` (group access); NixOS `ReadWritePaths`; NixOS `NoNewPrivileges` / `ProtectSystem = strict` / `PrivateTmp`; container identity hash schema version `4`.

The `backend.sessionTokenFile` mechanism (the desktop ↔ backend pairing) is described in the docs prose at `programs.hermes-agent` section but its actual option (`services.hermes-agent.backend.sessionTokenFile`) is not in the docs cheatsheet.

---

## 10. Anything in the source that contradicts the official docs

The docs are tier 2 ("best-effort"). A few concrete contradictions / omissions:

1. **`backend.waitFor = "interface"` on HM:** the docs do not mention this Darwin-only restriction. Source: `homeManagerModules.nix:351-353`:

   ```nix
   assertion = !isDarwin || cfg.backend.waitFor != "interface";
   message = "services.hermes-agent.backend.waitFor = \"interface\" works on Linux only. Use \"hostname\" on Darwin.";
   ```

2. **Documented update path:** the docs say "`sudo nixos-rebuild switch`" for NixOS and "`home-manager switch`" for HM (`website/docs/getting-started/nix-setup.md` "Managed Mode" section). The CLI itself says "nix profile upgrade, or update your flake input and rebuild with nixos-rebuild or home-manager switch" (`config.py:296-299`) — covering two cases: `nix profile install` users and flake users.

3. **The `_LEGACY_MANAGED_SYSTEM = "nixos"`** is what `HERMES_MANAGED=true|1|yes` resolves to. Older documentation may have said the marker is just a boolean; in fact it carries a system name (`"nixos"` or `"home-manager"`) and the CLI uses that name in the error message.

4. **`hermesHome` is missing from docs.** It is the HM-only option that replaces the NixOS `stateDir + "/.hermes"` derivation. Anyone following the cheatsheet row "Change state directory → `stateDir = "/opt/hermes"`" on Home Manager will get a module error — HM has no `stateDir`.

5. **`installPackage` removed.** The HM module still declares the option as an `mkOption` with `visible = false` and a `nullOr bool` type — only to assert that it's been removed and emit the replacement message. Source: `homeManagerModules.nix:280-287` plus assertion at `homeManagerModules.nix:317-322`. The removal message text (`moduleCommon.nix:661-673`):

   > "`services.hermes-agent.installPackage` was removed. Hermes now separates the installation from the services, which is the Home Manager convention:
   >
   > `programs.hermes-agent.enable = <was-it-true>;`  # the hermes CLI, and HERMES_HOME for your shells
   > `programs.hermes-agent.desktop.enable = true;`  # the desktop application
   >
   > `services.hermes-agent` keeps the state, the configuration and the daemons. Remove `installPackage` and add the line above."

6. **Hermes Desktop + service pairing.** When `services.hermes-agent.enable` is true AND `backend.mode != "none"` AND `backend.sessionTokenFile` is set, the launcher for `hermes-desktop` reads the same token at start time and connects to the service backend (`homeManagerModules.nix:99-118`). With `HERMES_DESKTOP_REMOTE_TOKEN` set, the application does not start its own backend. This is in the docs (`website/docs/getting-started/nix-setup.md` "`programs.hermes-agent`" section) but the **mechanism** (token read with `tr -d '\r\n'` from a runtime path) is only verifiable in source: `homeManagerModules.nix:103-111`, `moduleCommon.nix:940-958`.

7. **Container-aware CLI routing.** The docs section "Container-aware CLI" describes transparent routing via `${HERMES_HOME}/.container-mode`. The marker file is written by `nixosModules.nix:506` (`install -o hermes -g hermes -m 0644 ${containerModeFile} ${hermesHome}/.container-mode`) and is removed when `container.enable = false` (`nixosModules.nix:510`). The CLI reader is `get_container_exec_info()` at `~/.hermes/hermes-agent/hermes_cli/config.py:453-481`. The docs do not mention the file's exact name (`.container-mode`), only its effect.

---

## 11. Summary of the workstation path

For a workstation using Home Manager (no NixOS), the relevant option tree is:

- `services.hermes-agent` — state and daemon configuration.
  - `enable = true`
  - `hermesHome = "${config.home.homeDirectory}/.hermes"` (default)
  - `workingDirectory = config.home.homeDirectory` (default)
  - `gateway.enable = true` (HM-only; NixOS has no such option)
  - `backend.mode = "serve"` or `"dashboard"` for Hermes Desktop
  - `backend.sessionTokenFile = config.sops.secrets."hermes/desktop-token".path;` for the launcher pairing
  - `environmentFiles = [ config.sops.secrets."hermes-env".path ];` for LLM API keys
  - `settings.model.default = "anthropic/claude-sonnet-4";` for the model
  - `hermesHomeFiles."SOUL.md" = "...";` for the agent identity
  - `mcpServers.<name> = { command = ...; args = [...]; };` for MCP servers
  - `extraArgs = [ "--verbose" ];` if needed
- `programs.hermes-agent` — installation surface (HM-only).
  - `enable = true` (puts `hermes` on PATH; exports `HERMES_HOME` for shells)
  - `desktop.enable = true` (installs the Electron app with an XDG launcher; uses the same `hermesHome` via the launcher `extraEnv`)

Linger is required for the systemd user service — the HM module does not set linger (it cannot run `loginctl enable-linger`). The header at `homeManagerModules.nix:40-44`:

> "CAUTION: Enable linger for the account. Without linger, systemd stops the user manager at logout, and both units stop with it. Home Manager cannot run `loginctl enable-linger`. On NixOS, set `users.users.<name>.linger = true;` On other systems, run `loginctl enable-linger <name>` one time."

On Arch Linux, run `loginctl enable-linger <name>` once. After activation, the gateway runs as `systemd --user` unit `hermes-agent.service` (Linux) or launchd agent `org.nix-community.home.hermes-agent` (Darwin) — see `homeManagerModules.nix:152-177` and `396-401`.

---

## Appendix A — Source file line references

| Topic | Reference |
|---|---|
| Shared option definitions | `~/.hermes/hermes-agent/nix/moduleCommon.nix:229-650` |
| `deepConfigType` | `~/.hermes/hermes-agent/nix/moduleCommon.nix:31-36` |
| `mkConfigFiles` (Nix-side render) | `~/.hermes/hermes-agent/nix/moduleCommon.nix:688-703` |
| Merge script | `~/.hermes/hermes-agent/nix/configMergeScript.nix:6-33` |
| Activation state setup | `~/.hermes/hermes-agent/nix/moduleCommon.nix:772-890` |
| `.managed` marker write | `~/.hermes/hermes-agent/nix/moduleCommon.nix:856-858` |
| `processEnvironment` (HERMES_HOME + HERMES_MANAGED) | `~/.hermes/hermes-agent/nix/moduleCommon.nix:1046-1054` |
| `environmentFiles` semantics | `~/.hermes/hermes-agent/nix/moduleCommon.nix:292-309`, `734-758` |
| `authFile` semantics | `~/.hermes/hermes-agent/nix/moduleCommon.nix:323-338`, `865-874` |
| HM `hermesHome` | `~/.hermes/hermes-agent/nix/homeManagerModules.nix:256-271` |
| HM `gateway.enable` | `~/.hermes/hermes-agent/nix/homeManagerModules.nix:289` |
| HM `managedSystem` | `~/.hermes/hermes-agent/nix/homeManagerModules.nix:70` |
| HM activation wiring | `~/.hermes/hermes-agent/nix/homeManagerModules.nix:370-392` |
| NixOS `stateDir` default | `~/.hermes/hermes-agent/nix/nixosModules.nix:282-286` |
| NixOS tmpfiles | `~/.hermes/hermes-agent/nix/nixosModules.nix:444-451` |
| NixOS `addToSystemPackages` | `~/.hermes/hermes-agent/nix/nixosModules.nix:288-296`, `377-380` |
| Container mode | `~/.hermes/hermes-agent/nix/nixosModules.nix:299-339`, `636-711` |
| CLI `is_managed()` / `get_managed_system()` | `~/.hermes/hermes-agent/hermes_cli/config.py:271-291` |
| CLI `format_managed_message` / `managed_error` | `~/.hermes/hermes-agent/hermes_cli/config.py:440-450` |
| CLI `_NIX_UPDATE_MSG` | `~/.hermes/hermes-agent/hermes_cli/config.py:296-299` |
| Managed constants | `~/.hermes/hermes-agent/hermes_cli/config.py:256-268` |

---

## Appendix B — Quick verification commands

If the local clone at `~/.hermes/hermes-agent/` is up to date, the following grep confirms the option list without re-reading all files:

```bash
rg -n 'mkOption|inherit.*type = types' ~/.hermes/hermes-agent/nix/moduleCommon.nix
rg -n 'mkOption' ~/.hermes/hermes-agent/nix/homeManagerModules.nix
rg -n 'mkOption' ~/.hermes/hermes-agent/nix/nixosModules.nix
rg -n 'HERMES_MANAGED|is_managed|managed_error|_LEGACY_MANAGED_SYSTEM|_NIX_MANAGED_SYSTEMS' \
  ~/.hermes/hermes-agent/hermes_cli/config.py
```

If the local clone is missing (T-04 cutover), the upstream raw URLs are:

- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/nix/moduleCommon.nix`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/nix/homeManagerModules.nix`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/nix/nixosModules.nix`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/nix/configMergeScript.nix`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/flake.nix`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/hermes_cli/config.py`
- `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/website/docs/getting-started/nix-setup.md`