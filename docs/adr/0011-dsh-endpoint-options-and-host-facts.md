# 0011 — The dsh endpoint owns its facts as `dsh.*` options; host facts get their own module

**SUPERSEDED IN PART 2026-09-30 by ADR 0012:** `dsh.entryPort` and its
consumer `dsh/phone-entry.py` are deleted. The remaining interface
(`dsh.port`, `dsh.home`, `dsh.publicName`), the host-facts seam, and the
port-less derivation stand.

Two seams that were in the wrong place move to where the consumers already
stand. First: the measured facts of a host — its tailnet address and MagicDNS
name — are declared as **`host.tailnetIp` / `host.tailnetName`** in
`modules/host.nix`, set by the same hostname profiles that set ingress
behavior (`profiles.hostname.<name>.module = { host = …; ingress = …; }`).
Before this, they lived as `ingress.*` options and `modules/dsh.nix` read
`config.ingress.tailnet*` across the seam: the dsh module was not importable
without the ingress module, and the next consumer would have repeated the
reach. Second: the **dsh endpoint** (CONTEXT.md) gets an interface —
`dsh.port`, `dsh.entryPort`, `dsh.home`, `dsh.publicName`, declared in
`modules/dsh.nix` with the measured values as defaults. Everything that used
to restate them — the Caddyfile's `dshSite` block in `modules/ingress.nix`,
the redirector's constants in `dsh/phone-entry.py`, and the `dsh:open` /
`dsh:smoke` task bodies — now interpolates. The port-less site address
(`siteAddress`, and the `443` behind it) is derived inside the dsh module:
the cookie is bound to the exact authority (D42), so serving a port would
mint the wrong cookie, and an assertion refuses a `dsh.publicName` carrying a
port or path. `dsh.home` is evaluated from `config.devenv.root`, the checkout
path being identical on both machines; the runtime `DSH_HOME:-$PWD` fallback
is deleted — relocating the home is now a declaration edit.

## Why (the survey, the deletion test)

The architecture review (2026-09-30) found one domain concept, the dsh
endpoint, copy-pasted across eight files: `127.0.0.1:3080` six times,
`dsh.hbohlen.space` nine, `:3082` three, with the contract between the Nix
side and `dsh/phone-entry.py` enforced by a comment ("must match the dsh
`--port` in modules/dsh.nix") across a language boundary. Deleting any copy
scattered the fact into the remaining ones — the signature of a missing
interface, not of a shallow module. Both machines run the identical endpoint,
so nothing in the set is a host fact; only the Caddy in front differs.

## What does not change

No value moves: the ports, the name, the capture path (`<home>/launch.url`),
and the rendered Caddyfile are byte-for-byte what they were — verified by
forcing the old and new renders on contabo and stub-evaluating the netcup
shape. contabo's system Caddy (out of repo, D42/ADR 0002) fronts the same
loopback ports and needs no edit. `ingress.serveDsh`, the hostname-profile
selection (D50), and the promotion (ADR 0008) stand as decided; this relocates
where the facts live inside the shell layer, nothing else. Ingress reading
`config.dsh.*` is the one new cross-module read, and it points the honest
direction: the front asks the upstream what it is.

## Consequences

- `modules/dsh.nix` imports without `modules/ingress.nix` (it now reads only
  `config.host.*`, whose null defaults keep D3's unprofiled-host property).
- A future port or name change is a one-option edit; the smoke test follows
  the declaration automatically, so the interface is the test surface.
- `dsh:smoke` hardcodes no port anymore — including the `:443` it once
  asserted while the ingress ports were options, which was the abstraction
  leaking backwards.
- Registration machinery for multiple upstreams is deliberately NOT built:
  one adapter is a hypothetical seam; `modules/ingress.nix` interpolating
  `config.dsh.*` is enough until a second port-less site exists.
