# Diagnosis: `secretspec.enable = true` is NOT portable — D45.1/ADR 0009's fallback claim is false (devenv 2.4.0)

**Date:** 2026-09-30
**Reporter:** the hermes-config effort (ticket 05 verification + ticket 07 design)
**Symptom:** the amendment recorded as D45.1 / ADR 0009 says:

> "`secretspec.enable = true` is portable: the upstream module's `enable` is
> `readOnly` and falls back to `false` when no vault is available, so a
> tokenless shell still enters."

Measured against devenv 2.4.0+b904dcb (the locked binary), the fallback does
not exist on any normal command path. The claim conflates two different code
paths. This document replaces it with the measured behaviour.

## What was measured

### 1. The Rust path — where `enable: true` actually leads (`devenv/src/devenv/mod.rs`)

`resolve_secretspec_into` (mod.rs:4265) runs whenever the project has a
`secretspec.toml` AND `devenv.yaml` says `enable: true`:

```rust
let validated_secrets = match secrets.validate()? {
    Ok(validated) => validated,
    Err(e) => {
        return Err(SecretsNeedPrompting {           // mod.rs:4327
            provider, profile, missing: e.missing_required, source: …
        }.into());
    }
};
```

The error propagates through `?` at mod.rs:653 out of `Devenv::load`. In
`main.rs:162`, a `SecretsNeedPrompting` error is caught ONLY to prompt the
operator interactively; in a non-terminal invocation
(`can_use_stdin_interactively() == false`) it is returned unchanged — the
command fails. There is no path in which `enable: true` resolves to
`enable: false` silently.

### 2. The Nix path — where the `readOnly` default lives (`src/modules/integrations/secretspec.nix`)

```nix
enable = lib.mkOption {
  type = lib.types.bool;
  default = if secretspecData != null then true else false;
  readOnly = true;
};
```

`secretspecData` is whatever the CLI injected via `_module.args`. The
fallback this option implements is "the CLI passed nothing → false". It does
NOT re-decide anything about the YAML: by the time Nix evaluates, the CLI has
already either resolved the profile (success) or aborted (failure). The
`readOnly` + default-false mechanism is what D45.1 read as the fallback; it
is downstream of the only gate that matters.

### 3. The one real exception — `machines install`

`main.rs:634`:

```rust
let expose_secretspec_values_to_nix = !matches!(
    &command,
    Commands::Machines { command: MachinesCommand::Install { .. } }
);
```

For `machines install` ONLY, the CLI skips workstation-side resolution
entirely (deferred/target-side resolution; mod.rs:644-648 comment). That is
the single code path where `enable: true` does not touch the vault. It is
also exactly why D45's original rule — *the shell does not resolve; the
machine path opts in per invocation* — held up in measurement.

### 4. Behavioural consequence for the hermes sub-project

With `hermes/secretspec.toml` present and `hermes/devenv.yaml` carrying
`secretspec.enable: true`:

- Every `devenv info/build/eval/shell/test` from `~/nix/hermes` requires
  `OP_SERVICE_ACCOUNT_TOKEN` + `SECRETSPEC_REASON` (require_reason is set in
  the manifest) even when no secret is consumed.
- A tokenless `devenv build machines.workstation.build.home-manager` exits 1
  at the provider gate. Measured indirectly: the same gate is what D45's
  ticket-07 audit measured on the root project ("tokenless … exit 1 at the
  1Password provider gate").
- The activation package itself needs no secret VALUES (see below), so the
  integration buys nothing for the build path while costing every invocation
  the vault.

## Why the design does not need `config.secretspec.secrets.*` at all

Two facts, both verified against pinned sources:

1. **Upstream reads `.env` at RUNTIME.** `moduleCommon.nix`'s `mkEnvScript`
   installs `$HERMES_HOME/.env` at each activation from `environment`
   (store-safe, non-secret) plus `environmentFiles` (paths outside the
   store), and hermes reloads the file at each start
   (`load_hermes_dotenv()`). Secrets therefore never need to enter the eval
   of the generation — they are concatenated from an on-disk file whose
   *contents* are not read by Nix. Passing a Nix *path* to a secret string
   would put the value in the world-readable store, violating ADR 0007.
2. **devenv passes secret values into eval only** (`secretspec_data_for_nix`,
   mod.rs:4186, `expose_values: true` on every non-install command). So
   referencing `config.secretspec.secrets.X` inside the machine declaration
   would route vault content through the store-adjacent eval of the HM
   generation — the exact thing the repo's rules forbid.

The correct shape: the `.env` is rendered imperatively by
`secretspec export`/`secretspec run` (outside Nix entirely), and the HM
module just points at its path. `environmentFiles =
lib.optionals builtins.pathExists [...]` keeps evaluation green before the
first render.

## Consequences for the tracker

- **D45.1 / ADR 0009: superseded** by this diagnosis. D45 (original) stands.
- **H12** in `.scratch/hermes-config/map.md` must be amended: the hermes
  sub-project ships `secretspec.enable: false` in `hermes/devenv.yaml`;
  rendering the `.env` is a plain `secretspec run` step (T-07's command),
  not a devenv integration.
- **Ticket 05's "what would fail it"** item "Forgetting `secretspec.enable:
  true`" is inverted: keeping it `true` is what fails the portability test.
- **Ticket 07** lands `hermes/secretspec.toml` declaring the six vault items
  (per-key refs, `as_path = true` where the consumer wants files) with
  enable off, plus a documented `secretspec export --format dotenv` render
  command. No devenv coupling.
- **Spec `docs/specs/hermes-config.md` §"Secretspec integration (per D45.1)"**
  needs a rewrite to the render-outside-Nix shape (its bash snippet also
  calls `config.secretspec.secrets.*` as a shell command, which was always
  pseudocode).

## Repro (cheap)

```sh
cd ~/nix/hermes && env -u OP_SERVICE_ACCOUNT_TOKEN -u SECRETSPEC_REASON \
  ~/nix/bin/devenv info          # with enable: true → dies at provider gate
# flip hermes/devenv.yaml to enable: false → exits 0 tokenless
```

## Source citations

- devenv 2.4.0 tarball b904dcb: `devenv/src/devenv/mod.rs:638-700`
  (resolve-on-load), `:4265-4360` (`resolve_secretspec_into`), `:4186-4198`
  (`secretspec_data_for_nix`), `devenv/src/main.rs:162-176`
  (`SecretsNeedPrompting` handling), `:634-640` (install exemption);
  `src/modules/integrations/secretspec.nix:22-49` (Nix-side defaults).
- hermes-agent bddd22be: `nix/moduleCommon.nix:291-347`
  (`environmentFiles`/`authFile` semantics), `:750-777` (`mkEnvScript`).
- Prior measurement: `.scratch/devenv-layering/map.md` D45 evidence block
  (tokenless `devenv test` with `enable: true` → exit 1).
