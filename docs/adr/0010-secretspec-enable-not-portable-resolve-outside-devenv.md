# 0010 — `secretspec.enable = true` is NOT portable; secrets resolve outside the devenv integration

Supersedes ADR 0009 and map decision D45.1 (both 2026-09-29). Measured against
devenv 2.4.0+b904dcb, locked source (`devenv/src/devenv/mod.rs`, `main.rs`):
whenever a project has a `secretspec.toml` AND `devenv.yaml` says
`secretspec.enable: true`, the CLI resolves the whole profile at EVERY command
load — `info`, `eval`, `build`, `shell`, `test`. On failure it raises
`SecretsNeedPrompting`, which non-interactively aborts the command. The only
skip is `machines install` (deferred target-side resolution). The Nix-side
option is `readOnly` with `default = if secretspecData != null then true else
false` — that fallback covers "the CLI injected nothing", never "resolution
failed"; ADR 0009 read the wrong mechanism. The claim "a tokenless shell still
enters" is therefore false on any project with a manifest.

The rule: D45 stands as written — the SHELL does not resolve secretspec; the
`machines`/`eval` paths opt in per invocation with
`SECRETSPEC_PROVIDER`/`SECRETSPEC_PROFILE` (+ `SECRETSPEC_REASON`).
`secretspec.enable` is `false` in every `devenv.yaml` in this repo, root and
sub-projects alike.

For tools that need secret FILES at runtime — hermes is the case that opened
this — values reach them without Nix ever seeing them: declare the keys in a
per-tree `secretspec.toml`, render imperatively
(`secretspec export --format dotenv > $HERMES_HOME/.env`), and point the
module option at the rendered path (`environmentFiles`, guarded by
`builtins.pathExists` so evaluation stays green before the first render).
This holds ADR 0007 ("no secrets in the store") by construction: referencing
`config.secretspec.secrets.X` inside a machine declaration would route vault
content through the eval of an activation package that gets copied to hosts.

Consequence accepted: with enable off, no Nix expression may consult secret
VALUES. Anything that needs them runs `secretspec run` itself, the way
`git push` already does (README.md's deploy loop). Full diagnosis:
`docs/research/2026-09-30-secretspec-enable-not-portable.md`.
