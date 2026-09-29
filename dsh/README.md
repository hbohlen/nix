# `dsh/` — the declared dsh Web instance's seed material

Everything for the declared dsh Web instance stays under this directory.
`modules/dsh.nix` runs the process from devenv, seeds the profile here, and keeps
runtime state (sessions, settings, launch token, and ignored credentials) here.

| Path | What it is |
|---|---|
| `settings.yaml` | Provider and UI settings, seeded into a NEW `$DSH_HOME` once. No secret is in it: providers name their key by environment variable (`apiKeyEnv`). |
| `plugins/remote-settings/` | The local plugin that makes Settings → Models usable from a non-loopback origin. This repository is its source of truth. |
| `plugins/remote-settings/cordis.patch.yml` | The plugin's own bundle patch: it inserts `remote-settings-runtime` into the tree. |
| `phone-entry.py` | Loopback-only redirector that makes the stable domain work as a phone bookmark by issuing dsh's current launch URL. |
| `.dsh/` | Runtime home selected by devenv (`DSH_HOME=$PWD/dsh/.dsh`); intentionally git-ignored. |

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

`$DSH_HOME` for the declared instance is `~/nix/dsh/.dsh`, selected by devenv:

- Two live dsh processes sharing one home silently prune each other's workspace
  session membership and can corrupt session logs (upstream Discussion #1485).
  devenv keeps this runtime home separate from any other dsh process.
- Runtime state belongs under `~/nix/dsh`; `.dsh/` is ignored by git so sessions,
  storages, launch tokens, and credentials cannot be committed accidentally.

Credentials are the operator's: `dsh` reads them from the environment or
`$DSH_HOME/.env`. The `.env` lives under ignored `dsh/.dsh/`, never in the Nix
store (ADR 0007).

## Ports and names

| Name | Port | Served by |
|---|---|---|
| `https://dsh.hbohlen.space` | 443 | system Caddy on the tailnet; tokenless `/` bootstraps through the loopback phone redirector, all other requests go to dsh on `127.0.0.1:3080` |

The upstream is `127.0.0.1:3080`. dsh binds its auth cookie to the browser-facing
`hostname:port`, so launch tokens must be exchanged through the exact domain URL
shown by `devenv tasks run dsh:open`. For phones, bare-domain visits redirect
to the current launch URL through the loopback-only helper; the system Caddy
route and devenv process must both be running. `docs/dsh-web-endpoint.md` is the
runbook.
