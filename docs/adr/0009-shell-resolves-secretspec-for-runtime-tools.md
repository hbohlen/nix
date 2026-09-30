# 0009 — `secretspec.enable = true` is portable; the shell layer can resolve secretspec

**SUPERSEDED 2026-09-30 by ADR 0010.** This decision's load-bearing claim was
never measured: devenv 2.4.0's Rust CLI resolves the profile at every command
load when `enable: true`, and a tokenless run aborts — the `readOnly` Nix-side
default it cited reflects "the CLI injected data", not a rescue of a failed
resolution. Diagnosis with source citations:
`docs/research/2026-09-30-secretspec-enable-not-portable.md`. Kept for the
record; D45 (the rule this purported to amend) stands unchanged.

D45 declared that the shell layer does not resolve secretspec; only `machines`
and `eval` do. The amendment: `secretspec.enable = true` is portable. The
upstream module's `secretspec.enable` is `readOnly` and falls back to `false`
when no vault is available, so a tokenless shell still enters. The four D3
prerequisites remain — a working vault is *optional*, not required, and tools
that need secrets reference `config.secretspec.secrets.X or ""` (silently
empty if no vault). `secretspec` and the `eval`/`machines` paths are now one
mechanism, not two. ADR 0009 supersedes the original "per-tool opt-in"
language in `devenv-layering/map.md` D45.1.