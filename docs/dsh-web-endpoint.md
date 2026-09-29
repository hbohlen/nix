# dsh Web endpoint — `dsh.hbohlen.space`

The DeepSeek Harness Web UI for this workstation, served to **tailnet clients
only**. `dsh` itself listens on `127.0.0.1:3080`; two Caddy sites front it. This
file is the runbook and the record of the decisions behind the shape.

Measured and verified 2026-09-29 on `contabo` (the operator workstation, tailnet
`100.115.197.61`).

## The decision: which Caddy serves the name

**End state — the shell ingress owns it.** `modules/ingress.nix` (wayfinder
ticket 06) declares the site, per D24: the shell's Caddyfile is the successor of
`/etc/caddy/Caddyfile` and the site moves to 443 when the ingress is promoted to
netcup's machine layer (ADR 0002, D8).

**Interim port answer — 9445.** The system `caddy.service` owns
`100.115.197.61:443` and is NOT in this repository, so the repo-declared site
binds a high port on the tailnet address (D21 coexistence). The port-less URL
stays on the system caddy's `*.hbohlen.space` site until promotion. That is the
recorded interim; the repository declares `:9445` and does not claim the other.

| URL | Served by | In this repo |
|---|---|---|
| `https://dsh.hbohlen.space` | system caddy, `*.hbohlen.space` site | no — interim |
| `https://dsh.hbohlen.space:9445` | shell ingress, `dsh.hbohlen.space:9445` site | yes |

**`dsh-dev.hbohlen.space` — explicit fate: left on the system caddy.** It serves
the `~/projects/deepseek-harness` dev checkout on `127.0.0.1:3081` with its own
profile, launched by hand. It is not declared here, and this change does not
touch it.

**Why the port is in the URL, and why the cookie cares.** dsh's session cookie
is authority-bound: the normalized `hostname:port` appears in the cookie name
and in its signed payload. A cookie minted at `dsh.hbohlen.space` is refused at
`dsh.hbohlen.space:9445` and the reverse (measured: both directions return 401 on
`/api`). So the operator must use the URL whose authority they minted, and the
`--trusted-host` set must contain the authority they type. The declared process
carries the port-less entry, which the fence matches on any port (measured in
`api-request-trust.ts`: a port-less entry compares hostnames only).

## What is declared, and where

| Concern | Where |
|---|---|
| Ingress site | `modules/ingress.nix` (`https://dsh.hbohlen.space:9445`) |
| dsh program | `modules/dsh.nix` — the pinned `llm.dsh`, under a pinned upstream Node |
| dsh Web process | `modules/dsh.nix` (`processes.dsh-web`) |
| Declared home seed | `modules/dsh.nix` + `dsh/` (settings, profile overlay, plugin) |
| Plugin source of truth | `dsh/plugins/remote-settings/` |
| Launch flow and smoke test | `modules/dsh.nix` (`tasks."dsh:open"`, `tasks."dsh:smoke"`) |
| DNS record | Cloudflare, DNS-only, `dsh.hbohlen.space → 100.115.197.61` |

## Operate

```console
# 1. Start the declared instance (loopback only)
devenv up dsh-web

# 2. Get a FRESH launch URL through the domain. A stored URL is never a
#    fallback: the token dies with its process.
devenv tasks run dsh:open
#    -> https://dsh.hbohlen.space:9445/?token=<43 chars>

# 3. Open that URL in a tailnet browser. The token exchange sets the
#    authority-bound cookie; the page then carries the settings shim.

# 4. The whole chain, asserted
devenv tasks run dsh:smoke
```

`dsh:smoke` asserts, in order: the process listens on `127.0.0.1:3080` and
nowhere else; the site answers on `100.115.197.61:9445`; a fresh token exchanges
through the domain (`303` + cookie); the served page carries the
`dsh-remote-settings-shim`; `/api` refuses a cookieless caller (`401`) and
accepts the domain cookie — which is the proof that the authority reaching dsh is
the one the cookie was minted for.

## The handover from the hand-launched instance (operator step)

Measured 2026-09-29: `127.0.0.1:3080` is held by a `systemctl --user` unit
(`dsh-web.service`) running the mise npm copy of dsh **0.1.5-rc.1** from
`~/.dsh`. Nothing in the repository declared it. The declared instance cannot
bind 3080 while it runs.

```console
systemctl --user disable --now dsh-web     # revert: systemctl --user enable --now dsh-web
devenv up dsh-web
```

**The declared home needs credentials first.** `~/.dsh-web` starts empty of
model credentials, so Models lists no provider until the operator provisions
them (`0600`, never committed, never in the store):

```console
install -d -m 0700 ~/.dsh-web
install -m 0600 /dev/null ~/.dsh-web/.env     # then fill in LONGCAT_API_KEY, DEEPSEEK_API_KEY
```

That is deliberate and is the reason this handover is not automated: pointing the
declared process at `~/.dsh` instead would migrate the operator's live 0.1.5 home
one way (0.1.7 imports `settings.yaml` and renames it `.imported`) and would put a
second live process on a home the dev checkout already shares — the failure
upstream documents as silently pruning workspace session membership.

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

- **The handover itself** (step above) — it needs the operator's credentials, and
  it stops a service the operator is using. The declared instance was verified on
  a spare port (`3082`) instead: same entry point, same home seed, same flags.
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