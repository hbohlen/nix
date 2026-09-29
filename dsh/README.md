# `dsh/` — the declared dsh Web instance's seed material

This directory holds the parts of the dsh Web UI setup that the repository owns.
`modules/dsh.nix` reads it; nothing here is runtime state.

| Path | What it is |
|---|---|
| `settings.yaml` | Provider and UI settings, seeded into a NEW `$DSH_HOME` once. No secret is in it: providers name their key by environment variable (`apiKeyEnv`). |
| `plugins/remote-settings/` | The local plugin that makes Settings → Models usable from a non-loopback origin. It lived only in `~/.dsh/plugins/` until 2026-09-29; the repository is now its source of truth. |
| `plugins/remote-settings/cordis.patch.yml` | The plugin's own bundle patch: it inserts `remote-settings-runtime` into the tree. |

## Why the plugin is needed

The Web client decides whether the settings document is writable from its own
page authority (`packages/client/connection/src/client/index.ts`): a page that is
not `localhost`/`127.0.0.0/8` gets an in-memory mirror, never sends
`settings.describe`, and the Models page fails with "settings are unavailable in
this browser". `--trusted-host` widens only the `/api` Host/Origin fence, not
that client-side scope.

The plugin taps the served `index.html` and injects a pre-boot shim that declares
the page as the transport owner (`ownsHost`). The client then uses the Host
settings document. It adds no authentication: dsh's browser-session cookie still
gates the page and every `/api` route, and the tailnet is the network boundary.

## The home

`$DSH_HOME` for the declared instance is `~/.dsh-web` — deliberately NOT `~/.dsh`:

- Two live dsh processes sharing one home silently prune each other's workspace
  session membership and can corrupt session logs (upstream Discussion #1485).
  The operator's `~/.dsh` already serves the hand-launched instance and the
  `~/projects/deepseek-harness` dev checkout on port 3081.
- The home is outside the repository so no runtime state (sessions, storages,
  credentials) can enter the tree.

Credentials are the operator's: `dsh` reads them from the environment or
`$DSH_HOME/.env`, never from this repository (ADR 0007).

## Ports and names

| Name | Port | Served by |
|---|---|---|
| `https://dsh.hbohlen.space` | 443 | the SYSTEM caddy's `*.hbohlen.space` site — interim, not in this repo |
| `https://dsh.hbohlen.space:9445` | 9445 | this repo's shell ingress (`modules/ingress.nix`) |

The upstream is `127.0.0.1:3080` for both. The session cookie is bound to
`hostname:port`, so the two URLs hold different cookies and neither works for
the other. `docs/dsh-web-endpoint.md` is the runbook.