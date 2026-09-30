# 0008 — Ingress promotion moves the shell stack to netcup; the NixOS role stays the six

At the D8 deploy the ingress stops being a workstation prototype by running the
**shell layer on netcup**, not by growing netcup's NixOS declaration. The
upstreams (hermes dashboard, the gateway adapters, dsh, the phone-entry
redirector) and the Caddy that fronts them all run as devenv `process`es on
netcup; Caddy binds the netcup tailnet address on port-less 443 and terminates
TLS with DNS-01. The NixOS role stays the irreducible six (research,
`devenv-machines-minimal-layer.md`), because the ingress remains shell-declared
per D2/D24. D51 later adds a separate Home Manager role for the operator's
pinned `devenv` CLI; it does not move the ingress or expand the NixOS role.
DNS for `hermes*.hbohlen.space` and `dsh.hbohlen.space` repoints from the
workstation's tailnet address (`100.115.197.61`) to netcup's, and the
workstation's out-of-repo `/etc/caddy/Caddyfile` route retires.

## Why not the alternatives (D46 Q1)

Rejected: **upstreams stay on the workstation, netcup's Caddy proxies to them.**
That makes netcup a redundant TLS hop — the URL still dies when the workstation
shell closes, because the upstreams are shell processes there — so promotion
would buy nothing but a second failure point.

Rejected: **cancel the promotion, keep the workstation system Caddy.** Least
work and no new netcup credentials, but it contradicts D8, D15 and D24, and
leaves the load-bearing Caddyfile permanently outside the repo, which is the
condition ADR 0002 exists to end.

## The three questions D46 raised

**Where the upstreams run.** On netcup, as shell processes, beside Caddy. This
promotes the stack rather than the machine.

**How `CF_API_TOKEN` reaches Caddy.** Unchanged in mechanism: Caddy is still a
shell `process`, so it reads `op://dev/CLOUDFLARE_API_TOKEN/token` with `op read`
at process start and the value lives only in that process environment (ADR
0007). Rejected for this shape: `install.secrets` (writes only at install time,
and would put the token on the machine path) and a systemd credential (there is
no machine-layer Caddy to consume it). The operator's `op` service-account token
must therefore exist on netcup in the environment where `devenv up` runs — the
same requirement the shell already has, and the one real new credential the
promotion places on the host.

**The dsh cookie stays authority-bound.** The promoted Caddyfile carries the
port-less `dsh.hbohlen.space` route in matcher order — the `@dshEntry` matcher
(tokenless, cookie-less root) before the catch-all `@dsh` matcher — exactly as
`docs/dsh-web-endpoint.md` records it. Copying only `modules/ingress.nix` would
drop it and break phone entry.

## Gaps this ADR does not close

- The hermes **gateway** upstream (`127.0.0.1:8644` webhook, `8642` api_server) is
  not declared in this repo; it is an external service driven by
  `~/.hermes/config.yaml`, and those adapters are currently disabled (the
  measured 502). Declaring or relocating it is ticket 08's work.
- The dsh home (`dsh/.dsh`), its model credentials, and `~/.hermes/config.yaml`
  must exist on netcup before the promoted stack serves anything.
- `modules/dsh.nix` and `modules/ingress.nix` hardcoded the workstation's
  tailnet name and address (`contabo.worm-hue.ts.net`, `100.115.197.61`).
  **Resolved by D50** (ticket 08 step 2): `ingress.*` options plus devenv
  hostname profiles in `devenv.nix` select the per-host address, name, ports,
  and whether that host owns the dsh route; the netcup profile renders
  port-less 443 and the `@dshEntry` + `@dsh` route.
