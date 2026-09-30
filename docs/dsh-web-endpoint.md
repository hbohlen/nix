# dsh Web endpoint — `dsh.hbohlen.space`

The DeepSeek Harness Web UI for this workstation, served to **tailnet clients
only**. `dsh` itself listens on `127.0.0.1:3080`, behind Caddy on tailnet `:443`. This
file is the runbook and the record of the decisions behind the shape.

Measured and verified 2026-09-29 on `contabo` (the operator workstation, tailnet
`100.115.197.61`).

## The decision: which Caddy serves the name

The system Caddy currently owns the hostname's `:443` route. `modules/dsh.nix`
declares the loopback-only upstream process. At ingress promotion (ADR 0002,
D8), the promoted stack is the **shell layer run on netcup** (ADR 0008), not a
NixOS declaration: the workstation Caddy route retires, and netcup's shell Caddy
carries the route. That Caddyfile is declared in `modules/ingress.nix`, rendered
only on a host whose `ingress.serveDsh` is true — which the `netcup` hostname
profile sets in `devenv.nix` (D50).

**The operator URL is port-less.** The system `caddy.service` owns
`100.115.197.61:443`; its `dsh.hbohlen.space` route reverse-proxies every
request to the devenv-managed dsh process on `127.0.0.1:3080`. The hostname
resolves to the machine's Tailscale IP, and both Caddy and dsh bind only to
loopback/tailnet addresses. dsh's launch token is per-process and must be
exchanged through the exact domain URL: `devenv tasks run dsh:open` prints
that URL for the CURRENT process, every tailnet device (phone included)
opens it once, and dsh then sets each browser's authority-bound session
cookie. Tailnet membership is the outer access boundary, as requested.

| URL | Served by | In this repo |
|---|---|---|
| `https://dsh.hbohlen.space` | system Caddy on tailnet `:443` → dsh | Caddy system config; dsh process is in this repo |

The old `dsh-dev.hbohlen.space` service and source checkout have been removed.

**Why the exact authority matters.** dsh's session cookie
is authority-bound: the normalized `hostname:port` appears in the cookie name
and in its signed payload. A cookie minted at `dsh.hbohlen.space` is refused at
another port (measured: both directions returned 401 on `/api`). Use the same
hostname and port for token exchange and later requests. The declared process
includes `dsh.hbohlen.space` in `--trusted-host`; a port-less entry matches that
hostname on any port (measured in `api-request-trust.ts`).

## What is declared, and where

| Concern | Where |
|---|---|
| Browser-facing ingress | System Caddy's `dsh.hbohlen.space` route on tailnet `:443` |
| Promoted ingress (netcup) | `modules/ingress.nix`, rendered on the host whose `ingress.serveDsh` is true (`profiles.hostname.netcup` in `devenv.nix`, D50) |
| dsh program | `modules/dsh.nix` — the pinned `llm.dsh`, under a pinned upstream Node |
| dsh Web process | `modules/dsh.nix` (`processes.dsh-web`) |
| Trusted authorities | `modules/dsh.nix`, from `host.tailnetName` per host (D50, ADR 0011) |
| System Caddy route | `/etc/caddy/Caddyfile` on contabo (outside this repo); proxies every `dsh.hbohlen.space` request to `127.0.0.1:3080` |
| Declared home seed | `modules/dsh.nix` + `dsh/` (settings, profile overlay, plugin) |
| Plugin source of truth | `dsh/plugins/remote-settings/` |
| Launch flow and smoke test | `modules/dsh.nix` (`tasks."dsh:open"`, `tasks."dsh:smoke"`); the smoke test resolves the tailnet address from `host.tailnetIp` and every endpoint fact from the `dsh.*` options (D50, ADR 0011) |
| DNS record | Cloudflare, DNS-only, `dsh.hbohlen.space → 100.115.197.61` (repoints to netcup at ticket 08 step 4) |

## Operate

```console
# 1. Start the declared process set, including dsh.
devenv up -d

# 2. Print the current token URL — the entry point for every device,
#    phones included (it is the only way to exchange a launch token).
devenv tasks run dsh:open
#    -> https://dsh.hbohlen.space/?token=<43 chars>

# 3. The whole chain, asserted
devenv tasks run dsh:smoke
```

`dsh:smoke` asserts, in order: the process listens on `127.0.0.1:3080` and
nowhere else; the site answers on `100.115.197.61:443`; the current
process token exchanges through the domain (`303` + cookie); the served page
carries the
`dsh-remote-settings-shim`; `/api` refuses a cookieless caller (`401`) and
accepts the domain cookie — which is the proof that the authority reaching dsh is
the one the cookie was minted for.

## Start the declared instance

The dsh Web process and its runtime home are managed by devenv. Start the
declared process set from the repository root:

```console
devenv up -d
```

The token is per-process and dies with it. A bare
`https://dsh.hbohlen.space/` visit with no token and no session cookie shows
dsh's authentication-required page — that is the expected answer now the
phone-entry redirector is gone; every device enters through a `dsh:open` URL.
If a device still shows authentication-required after opening the URL, its
stored cookie is stale: clear that browser's site cookies for
`dsh.hbohlen.space` and open a fresh `dsh:open` URL.

If `dsh:open` reports the captured token no longer exchanges, the process
restarted since the capture; `$DSH_HOME/launch.url` is written by the declared
`processes.dsh-web` start script from the server's own stdout (it never greps a
log), so restart through the declaration to re-capture:

```console
$ devenv processes restart dsh-web
```

The system Caddy `dsh` route is:

```caddyfile
@dsh host dsh.hbohlen.space
handle @dsh {
    reverse_proxy 127.0.0.1:3080
}
```

The launch token travels in the request URL during the exchange
(`/?token=…`), so do not enable Caddy access logs that record request URIs.
Each tailnet device performs the same dsh token exchange and gets its own
browser cookie.

**The declared home needs credentials first.** `~/nix/dsh/.dsh` starts empty of
model credentials, so Models lists no provider until the operator provisions
them (`0600`, never committed, never in the store):

```console
install -d -m 0700 ~/nix/dsh/.dsh
install -m 0600 /dev/null ~/nix/dsh/.dsh/.env # then fill in LONGCAT_API_KEY, DEEPSEEK_API_KEY
```

The devenv-managed instance uses its own `dsh/.dsh`, separate from any other
running dsh process to avoid the shared-home corruption documented upstream.

## The Node blocker, recorded

The pinned `llm.dsh` (0.1.7-rc.2) **cannot boot under the Node it bundles**:

```text
dsh: fatal uncaught exception: Error: dsh: host preparation failed:
node-addon-require-builtin unsupported: Unsupported/no-getter
(x64 sysv getter is not a recognized this->field accessor)
```

The native addon that dsh uses to patch Node's internals matches compiled getter
code, and nixpkgs builds Node from source with different codegen. Measured:
nixpkgs `nodejs-24.20.0` fails, nixpkgs `nodejs-22.23.2` fails,
`NARB_BACKEND=nodeabi` fails with "No usable native binding", and
`nix build github:numtide/llm-agents.nix#dsh` at HEAD is the same store path — so
no pinned-version bump fixes it. The upstream Node 22 binary runs it.

`modules/dsh.nix` therefore runs the package's own entry point under a
hash-pinned upstream Node, and exposes that wrapper as `dsh`. Remove the wrapper
when the bundled Node stops failing the probe.

## Not verified in this change

- **The model provider credentials.** The declared home is isolated and must be
  provisioned as described above before model-backed requests can succeed.
- **Off-tailnet unreachability from a second vantage.** The record is DNS-only
  (not proxied) and points at `100.115.197.61`, an address in `100.64.0.0/10`
  that is not routable from the public internet; the site binds that address
  only. No off-tailnet vantage was available in this session.
- **The Models UI itself.** The mechanism is verified (the shim is in the served
  HTML, the fence accepts the domain authority); clicking through Settings is a
  browser check.
- **The settings import lands in pieces.** dsh 0.1.7 imports a legacy
  `settings.yaml` into the profile's `cordis.patch.yml` layer and renames the
  file `.imported`. Measured: after ONE boot a fresh home's patch layer carried
  `ui-settings-general` only; the provider section (`llm-pi-ai`) was present in
  the declared home that had booted twice. A brand-new home may therefore need a
  second start before Settings -> Models shows the seeded providers. The seed
  never re-creates `settings.yaml` once `.imported` exists, so this import can
  never overwrite the operator's later edits (verified: the patch layer's hash is
  unchanged by a re-seed).
