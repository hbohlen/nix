# The ingress — Caddy on the tailnet

Caddy terminates TLS for `hermes.hbohlen.space`, `hermes-gateway.hbohlen.space`
and `dsh.hbohlen.space`, bound to this host's **tailnet address** so only tailnet
clients have a route to it. This file is the operator's runbook for that
ingress. The dsh name has its own runbook
([`dsh-web-endpoint.md`](./dsh-web-endpoint.md)); the decisions behind this one
are ADR [0002](./adr/0002-shell-caddyfile-succeeds-system.md) (the shell
Caddyfile is the successor of `/etc/caddy/Caddyfile`) and
[0008](./adr/0008-ingress-promotes-to-netcup-stack.md) (the promotion runs the
shell stack on netcup).

Measured 2026-09-30 on `contabo`, tailnet `100.115.197.61`.

## 1. Where it runs, and for how long

The reverse proxy is a devenv **`process`**, not a system service (D15). It
starts with `devenv up` and dies when the shell's process manager does; while it
is up, the URLs answer, and not one minute longer.

While the shell Caddy coexists with the workstation's system `caddy.service`
(D21), the shell binds **high ports** and the system one keeps the tailnet's
`:443`:

| Site | Shell Caddy (declared here) | System Caddy (outside this repo) |
|---|---|---|
| `hermes.hbohlen.space` | `:9443` → `127.0.0.1:9119` | — |
| `hermes-gateway.hbohlen.space` | `:9444` → `:8644`, `/v1/*` → `:8642` | — |
| `dsh.hbohlen.space` | upstream + phone redirector only | `:443` → the dsh route (D42) |

Both shell sites `bind` the tailnet address, so a non-tailnet client has no
route to them. No firewall rule is added for that: the address itself is the
fence, and the system Caddy already owned `:443`.

## 2. Start it and check it

```console
# 1. start everything the shell declares
$ devenv up -d

# 2. assert the two Hermes sites are bound on the tailnet address
$ devenv tasks run ingress:smoke

# 3. read back the host facts the ingress is rendering
$ devenv eval ingress
```

`ingress:smoke` exits 0 when both ports are listening; on failure it prints
`ingress not listening on <ip>:<port>` and exits 1. `devenv eval ingress` prints
this on `contabo`, and is the fastest way to see which host profile is active:

```json
{ "ingress": { "enable": true, "tailnetIp": "100.115.197.61",
  "tailnetName": "contabo.worm-hue.ts.net", "dashboardPort": 9443,
  "gatewayPort": 9444, "serveDsh": false } }
```

Per-site checks that do not need the vault:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    --resolve hermes.hbohlen.space:9443:100.115.197.61 \
    https://hermes.hbohlen.space:9443/          # 200
$ curl -s -o /dev/null -w '%{http_code}\n' \
    https://hermes-gateway.hbohlen.space:9444/  # 404 (see §5)
```

## 3. The certificate path

Exact-name certificates via **Cloudflare DNS-01**. HTTP-01 cannot issue for a
name that does not route here, and a wildcard is not needed because every site
has its own name (D16). Stock Caddy cannot do Cloudflare DNS-01 — providers are
Go plugins compiled in — so `modules/ingress.nix` builds Caddy with
`pkgs.caddy.withPlugins` and
`github.com/caddy-dns/cloudflare@v0.2.4` (v0.2.4 accepts current `cfut_`
tokens). Renewal is Caddy's own certmagic; nothing here schedules it.

## 4. The token (ADR 0007)

`CF_API_TOKEN` is read from the vault at process start and lives only in that
process's environment:

```console
op read op://dev/CLOUDFLARE_API_TOKEN/token
```

It is never a Nix `env` entry, never a path literal, and never in the store. It
is **not** in the secretspec manifest — `secretspec get CLOUDFLARE_API_TOKEN`
fails — so the process reads the vault item directly rather than through
`secretspec run`. The invariant is the ADR's: vault, never store.

## 5. Known gaps

- The gateway's **api_server** (`127.0.0.1:8642`) is not running, so
  `hermes-gateway.hbohlen.space:9444/v1/*` answers 502. The webhook upstream
  (`8644`) is up, so `/` answers 404. Both adapters are configured in
  `~/.hermes`, outside this repo.
- `hermes.hbohlen.space` still A-records to `100.87.45.48`, the offline tailnet
  node `zepyhrus` — not to this host. Reach it with `--resolve` (above) until
  the record is repointed. Every other name resolves through the wildcard
  `*.hbohlen.space` to `100.115.197.61`.

## 6. One declaration, two hosts (D50)

The same modules run on the workstation and on the promoted netcup host, so the
host facts are **options**, `ingress.*`, and the values are selected by devenv's
**host profiles** in [`devenv.nix`](../devenv.nix):
`profiles.hostname.contabo.module.ingress` and `…netcup…`. devenv picks the
block from the running hostname.

| Option | `contabo` | `netcup` |
|---|---|---|
| `tailnetIp` | `100.115.197.61` | `100.95.168.15` |
| `tailnetName` | `contabo.worm-hue.ts.net` | `nc.worm-hue.ts.net` |
| `dashboardPort` / `gatewayPort` | `9443` / `9444` | `443` / `443` |
| `serveDsh` | `false` (system Caddy owns it) | `true` (renders the dsh route) |

A host with no profile keeps `enable = false` and null facts, so the shell still
evaluates on any machine with only the D3 prerequisites. `modules/dsh.nix`
reads the same options: `tailnetName` becomes a `--trusted-host` entry and
`tailnetIp` pins the dsh smoke test's `--resolve`.

Changing what a site serves means editing [`modules/ingress.nix`](../modules/ingress.nix);
the Caddyfile is generated there (`pkgs.writeText`), never written to `/etc`, so
it cannot drift from the module.

## 7. Promotion to netcup (ADR 0008, ticket 08)

The promotion runs the **shell stack on netcup** — it does not grow netcup's
NixOS declaration, which stays the irreducible six. Caddy then binds netcup's
tailnet address on **port-less 443** and carries the `@dshEntry` + `@dsh` route
in matcher order (the netcup profile already renders both; `caddy validate`
reports `Valid configuration`). DNS for the hermes and dsh names repoints from
`100.115.197.61` to netcup, and the workstation's out-of-repo route retires.

The remaining acts are ticket 08 steps 3–5: declare the hermes gateway upstream,
provision the dsh home, credentials and the `op` token on netcup, repoint DNS,
and deploy. Until then this section is the decision, not a description of a
running state.
