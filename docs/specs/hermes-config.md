# Spec: hermes-config

Workstation and netcup parity for the Hermes Agent install, declared through
devenv and the upstream `homeManagerModules.default` from
`github:NousResearch/hermes-agent`. The whole stack (binary, config,
runtime home, gateway, ingress coordination) becomes shell-layer-owned on
the workstation and is pushed to netcup from a single source.

Scope: workstation path + secretspec integration. Netcup parity is a
follow-on after the workstation lands.

## Why

`~/.hermes/` is currently an opaque 287KB home directory with config, OAuth
state, cache, history, and the venv install that drives the binary. It is
not declared anywhere, not in git, and not portable to netcup. The
upstream `hermes-agent` flake ships a NixOS module and a Home Manager
module; devenv 2.4 has a `machines.<name>.home-manager` role that can
activate home-manager locally (no `target.host`). Together those three
primitives let us declare hermes declaratively on the workstation, push it
to netcup as the single source, and recover the existing CLI workflow.

## Destination

`~/nix/hermes/` becomes a devenv-managed monorepo inside this repo:

    ~/nix/hermes/
    ├── devenv.nix            # workstation + netcup machine blocks
    ├── devenv.yaml           # inputs (hermes-agent, home-manager)
    ├── devenv.lock           # pins
    ├── .hermes/              # HERMES_HOME (set via services.hermes-agent.hermesHome)
    │   ├── config.yaml       # rendered by services.hermes-agent.settings
    │   ├── SOUL.md           # hermesHomeFiles."SOUL.md"
    │   ├── memories/         # hermesHomeFiles."memories/USER.md"
    │   ├── cron/             # declared subdir; hermes owns contents
    │   ├── bin/              # declared subdir; hermes-side scripts
    │   ├── bot_relay/        # declared subdir
    │   ├── assets/           # declared subdir
    │   ├── auth.json         # gitignored; authFile target
    │   └── .env              # gitignored; rendered by enterShell from secretspec
    ├── bin/                  # operator-facing wrapper scripts (devenv-managed)
    └── docs/                 # hermes-specific runbooks

The workstation activates hermes via `machines.workstation.home-manager`
(no `target.host`); the operator runs the activation package's `activate`
script. The same `services.hermes-agent` block appears on
`machines.netcup.home-manager` for parity (separate follow-on spec).

## Decisions (cross-reference)

See `.scratch/hermes-config/map.md` for the full interview record and
D45.1 in `.scratch/devenv-layering/map.md` for the (superseded) secretspec
amendment. ADR 0010 in `docs/adr/` records the measured rule:
`secretspec.enable` is FALSE; secret files render outside the CLI integration.

## Workstation path: `machines.workstation.home-manager`

```nix
# ~/nix/hermes/devenv.nix
{ inputs, ... }:
{
  imports = [
    /shared                                  # absolute-path: ~/nix/shared/devenv.nix
    inputs.hermes-agent.homeManagerModules.default
  ];


  machines.workstation = {
    system = "x86_64-linux";
    # NO target.host: activates locally per upstream source
    home-manager = {
      imports = [ inputs.hermes-agent.homeManagerModules.default ];

      home.username = "hbohlen";
      home.homeDirectory = "/home/hbohlen";

      # Linger is required for the systemd user service. Home Manager cannot
      # enable it; the operator runs `loginctl enable-linger hbohlen` once
      # before the first activate. See upstream HM module header.
      # (TODO: assert this in D-01 / runbook)

      programs.hermes-agent = {
        enable = true;                       # puts `hermes` on PATH; sets HERMES_HOME
        # desktop.enable = true;             # optional Electron app
      };

      services.hermes-agent = {
        enable = true;
        # HM-only option (NixOS has `stateDir`; HM has `hermesHome`)
        hermesHome = "/home/hbohlen/nix/hermes/.hermes";
        # HM-only; NixOS does not have this option (NixOS service is always on)
        gateway.enable = true;
        # points at the file `secretspec export` renders (T-07), guarded by
        # builtins.pathExists so evaluation is green before the first render
        environmentFiles = lib.optionals (builtins.pathExists
          "/home/hbohlen/nix/hermes/.hermes/.env")
          [ "/home/hbohlen/nix/hermes/.hermes/.env" ];
        # null: OAuth lands through hermes's own flow at cutover; upstream
        # first-write-wins keeps the runtime file across activations.
        authFile = null;

        # Translated verbatim from the live ~/.hermes/config.yaml.
        # The HM module's deepConfigType merge handles lib.recursiveUpdate
        # across multiple module contributors; the on-disk config.yaml is
        # PyYAML-rendered with the keys here deep-merged on top of any
        # runtime-added keys (per upstream docs/research/2026-09-29-...).
        settings = {
          model = {
            default = "deepseek/deepseek-v4.1-flash";
            provider = "nous";
            base_url = "https://inference-api.nousresearch.com/v1";
          };
          database.journal_mode = "wal";
          runtime.nofile_soft_limit = 4096;
          agent.max_turns = 150;
          # ... rest of the live config translated 1:1 ...
          terminal.backend = "local";
          terminal.timeout = 180;
          # auxiliary.* and tool_loop_guardrails preserved from upstream
        };

        # Identity / memory declared by Nix (must be hermesHomeFiles,
        # NOT documents — hermes reads SOUL.md / memories/ from HERMES_HOME)
        hermesHomeFiles = {
          "SOUL.md" = ./docs/SOUL.md;
          "memories/USER.md" = ./docs/USER.md;
        };
      };
    };
  };
}
```

Activate locally:

```sh
cd ~/nix/hermes
devenv build machines.workstation.build.home-manager
./result/activate                       # runs devenv's driver → upstream activate as hbohlen
```

The `result` symlink is the standard `devenv build` output: it points at
`/nix/store/<hash>-devenv-home-manager-generation`, which is a `symlinkJoin`
whose top-level `activate` is devenv's wrapper script (runuser → sudo →
error). The wrapper re-execs the real upstream home-manager activate as
the configured home-manager user. **There is no `devenv machines apply
workstation`** for the no-target case — the upstream CLI's `MachinesCommand`
enum has `Info`, `Plan`, `Apply` (requires saved plan), `Status`, `Rollback`,
`Check`, `Install` (NixOS-only), `Deploy`, but no local-activate variant.
The operator runs `./result/activate` manually (or wraps it in a devenv
task). Per `docs/research/2026-09-29-devenv-machines-hm-local.md` §3.5.

**One-time prerequisite on Arch Linux** (cannot be automated by Home
Manager): `loginctl enable-linger hbohlen`. Without it, systemd stops the
user manager at logout, and the gateway service stops with it.

## Secretspec integration (amended 2026-09-30 — ADR 0010 supersedes D45.1; ADR 0013 moves the provider to Doppler)

`hermes/devenv.yaml` carries `secretspec.enable = false`. The original design
here relied on D45.1's claim that `enable = true` is portable ("auto-falls
back to `false` when the vault is unavailable"); measured against devenv
2.4.0's source, that fallback does not exist: with a manifest in the tree and
enable true, EVERY command load resolves the profile and a tokenless run
aborts (`docs/research/2026-09-30-secretspec-enable-not-portable.md`). It was
also never needed — nothing in the Nix evaluation may reference secret VALUES
(ADR 0007), so `config.secretspec.secrets.*` was the wrong primitive from the
start.

The corrected shape: `hermes/secretspec.toml` declares each API-key secret by its
verbatim name (Doppler has no item/field addressing — ADR 0013), and ONE
imperative step renders them into the gitignored file (run from `~/nix/hermes`;
no enterShell hook):

```sh
# render $HERMES_HOME/.env (ticket T-07; re-run whenever a key rotates)
DOPPLER_TOKEN=$(cat ~/.config/doppler-token) \
  SECRETSPEC_REASON="hermes: render HERMES_HOME/.env" \
  secretspec export --format dotenv > .hermes/.env
chmod 0600 .hermes/.env
```

The token prefix is belt-and-braces: `modules/shell.nix` already exports
`DOPPLER_TOKEN` into the activation environment, and the explicit form is here so
the step runs from a shell that never activated.

Upstream then cats this file into `$HERMES_HOME/.env` at activation
(`mkEnvScript`) and hermes re-reads it at every start (`load_hermes_dotenv`).
`modules/hermes.nix` points `environmentFiles` at the rendered path guarded by
`builtins.pathExists`, so evaluation stays green before the first render.
Non-secret `.env` knobs (timeouts, debug flags, base URLs) belong in
`settings.nix` / `services.hermes-agent.environment`, not in the manifest.

`auth.json` is left for the cutover step (manual OAuth re-authorization);
`authFile = null` in the module — there is no bootstrapping file — and
`authFileForceOverwrite` stays default (off), so once written it persists
across rebuilds (first-write-wins).

## Cutover

Fresh + manual OAuth (per round 5). The live `~/.hermes/` is archived to
`~/archive/hermes-2026-09-29/` before the new tree is activated; OAuth on
each messaging platform is re-authorized through hermes's normal flow.

## Out of scope (this spec)

- **Netcup parity.** Separate follow-on spec once the workstation lands
  and is verified. The shape is `machines.netcup.home-manager` with
  `target.host = "root@nc.worm-hue.ts.net"` and the same
  `services.hermes-agent` block. Driven by the workstation's
  `outputs.hermes-config` derivation; netcup's devenv declares
  `inputs.workstation.devenv.config.outputs.hermes-config` and consumes it
  inside its `machines.netcup.home-manager` block.
- **DSH parity.** Out of scope. DSH is its own effort.
- **Hermes UI / desktop mode.** Out of scope. The CLI + gateway are in
  scope.

## Test plan

Measured 2026-09-30 (T-05/T-06/T-07): tokenless `devenv info`/`eval` exit 0;
`devenv build machines.workstation.build.home-manager` builds green cold
(1916s) and warm; the generated config diff vs live is exactly
`terminal.cwd`. Remaining items below are T-08's acceptance.

- `devenv test` green on the workstation (the existing four-D3-prereq
  shell layer still evaluates; hermes doesn't break it).
- `devenv build machines.workstation.build.home-manager` produces an
  activation package.
- `result/activate` runs as hbohlen (no sudo needed) and writes
  `~/nix/hermes/.hermes/config.yaml` from the upstream module.
- `hermes --version` matches the upstream flake version.
- `hermes --tui` opens a TUI; `hermes chat "hello"` returns a non-empty
  response from `deepseek/deepseek-v4.1-flash` (proves the env keys
  loaded).
- `cat ~/nix/hermes/.hermes/.env | head` shows the API keys rendered from
  secretspec; `chmod 0600` is correct.
- `cat ~/nix/hermes/.hermes/.managed` is present (managed mode active);
  `hermes config edit` refuses with a "managed" error.
- Re-activation is idempotent: a second `result/activate` run is a no-op.

## Open research tickets (blockers-first)

These are the inputs to `/to-tickets` once this spec lands. Each ticket
declares its edges.

1. **R-01 (RESEARCH): read the upstream hermes-agent Home Manager module
   source.** Grounded in the upstream Nix module at
   `github:NousResearch/hermes-agent`. Outputs: the exact
   `services.hermes-agent.*` option list (including the readme's
   documentation gaps), the `settings` schema, the `environmentFiles` /
   `authFile` semantics, the `stateDir` semantics, and the managed-mode
   trigger. **Blocked by:** nothing. **Blocks:** R-02, R-03.
2. **R-02 (RESEARCH): translate live `~/.hermes/config.yaml` to the
   `settings` attrset.** Map every top-level key in the live config to the
   upstream module's option. Outputs: the exact attrset to drop into
   `services.hermes-agent.settings`. **Blocked by:** R-01.
3. **R-03 (RESEARCH): read devenv 2.4's `machines.nix` source end-to-end
   for the home-manager role.** Confirm `target.host = null` activates
   locally; confirm what `devenv machines` CLI commands exist for
   home-manager-only machines (build, activate, status); confirm the
   activation package shape. **Blocked by:** R-01.
4. **T-01 (TASK): wire up `devenv.yaml` inputs.** Add `hermes-agent` and
   `home-manager` inputs. **Blocked by:** R-01, R-03.
5. **T-02 (TASK): write `modules/hermes.nix` and import it.** Translate
   R-02's settings attrset into `~/nix/hermes/modules/hermes.nix`. **Blocked by:** R-02.
6. **T-03 (TASK): write `secretspec.toml` entries.** Declare `hermes-env`
   and the individual API key secrets. **Blocked by:** R-01.
7. **T-04 (TASK): cutover.** Archive `~/.hermes/`, activate the new tree,
   re-authorize OAuth. **Blocked by:** T-01, T-02, T-03, T-05.
8. **T-05 (TASK): gitignore `auth.json` and `.env` in `~/nix/hermes/.hermes/`.** **Blocked by:** nothing.
9. **D-01 (DOCS): write `~/nix/hermes/docs/runbook.md`.** Operator-facing
   docs for the activate / restart / OAuth flow. **Blocked by:** T-04.

## Spec author / approver

Author: grilling interview 2026-09-29.
Approver: pending user review.