# 0006 — All fifteen scripts deleted; fresh ones written on need

The fifteen shell scripts are deleted without porting any to devenv `tasks`.
Ticket 02 measured 8–9 of 15 as task-eligible, but the decision is delete-all:
a port would spend effort immortalising glue around mechanisms the layering
already replaces, and a fresh script written against the shell layer is the
cheapest correct form when a need reappears. Consequences, accepted: the
per-pane token backfill the three worst scripts did is replaced by the
activation-environment export in `modules/shell.nix` (D36); the two
operator-verify scripts' replacements are ticket 08's problem (D35); and
`hosts/netcup/self-deploy.nix:159` is the one tracked string that still names a
deleted script, to be corrected when that module is next touched.
