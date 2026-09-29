# 0001 — One root project; per-tool-group modules; no profiles

`~/nix/devenv.nix` imports `./modules/*.nix`, one module per tool group, and is
the only devenv project: nested projects and profiles are rejected for now.
Profiles were rejected because D12 already moves everything into one config, so
profiles would be ceremony around a decision already made; per-group modules
won because devenv has no documented guidance for splitting a large
`devenv.nix`, and named groups let each record which decision put it there.
The layout is load-bearing: `devenv.yaml` imports anchored at `/modules/`
resolve from any subdirectory, which is what future nested projects would use.

Considered: profiles for workstation-vs-host splits (activation-gated, worst
for sharing per upstream practice); multiple nested projects from day one
(no second project exists yet).
