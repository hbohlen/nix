# @hbohlen/remote-settings

Fixes **`Loading the provider directory failed: settings are unavailable in this browser`**
when the dsh Web UI is opened through a non-loopback origin (here:
`https://dsh.hbohlen.space` → Caddy → `127.0.0.1:3080`).

## Why it breaks

The web client scopes settings by the page's own authority:

| code | effect |
| --- | --- |
| `client/connection` → `isLoopback: transport?.ownsHost === true \|\| pageLocation === undefined \|\| isLoopbackHostname(pageLocation.hostname)` | a page at `dsh.hbohlen.space` is **not** loopback |
| `client/ui/settings` → `persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'` | mirror is created in **memory** mode, never sends `settings.describe` |
| `client/ui/settings-models` → `failLoad(… mirrored.error ?? 'settings are unavailable in this browser')` | the Models page shows the error |

`--trusted-host dsh.hbohlen.space` only widens the Host/Origin fence on `/api`
(so the RPC *would* be accepted); it does not change the client-side scope.
This is upstream's deliberate design, not a Caddy/DNS misconfiguration — see
deepseek-harness discussion #4695.

## What it does

`ctx.webServer.tapIndex` injects a pre-boot shim into the served `index.html`
that sets `globalThis.__DSH_TRANSPORT__ = { ownsHost: true }` when the page is
not already on a loopback hostname. That flips the single predicate above to
`true`, so the settings mirror binds to the Host document; the transport itself
is untouched (`createWebConnectionRpc(undefined, undefined)` → real
`fetch` + Gateway WebSocket, exactly as before).

Blast radius: `isLoopback` is read in exactly two places — the settings mirror
persistence and the settings document store. Nothing else changes.

## Security scope

* No authentication is added or bypassed. The page and every `/api` route still
  require dsh's browser-session cookie; the Host fence still applies.
* Intended for a host that untrusted parties cannot reach (here the DNS record
  is DNS-only → tailnet IP `100.115.197.61`, so only tailnet members connect).
* Do **not** copy this onto a publicly reachable deployment.

## Dev loop

```sh
cd ~/nix/dsh/plugins/remote-settings
dsh plugin --profile web add .      # re-copy into the profile
devenv processes restart dsh-web    # code changes never hot-reload
```

Verify the shim is served:

```sh
curl -s http://127.0.0.1:3080/ -H 'Host: dsh.hbohlen.space' -H "Cookie: <dsh-auth>" | grep -c dsh-remote-settings-shim
```

If upstream ever relaxes the loopback gate (e.g. a `settings.persistence`
config), delete this bundle: `dsh plugin --profile web remove @hbohlen/remote-settings`.
