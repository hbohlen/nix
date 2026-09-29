# 0002 — The shell Caddyfile succeeds /etc/caddy/Caddyfile

The shell owns the Caddyfile definition; the machine keeps serving its old one
only until promotion. During the prototype the shell Caddy runs beside the
system `caddy.service` on high ports, and at the D8 deploy the shell definition
promotes to netcup and the system copy retires. Reason: D2 — the shell
declares, the machine inherits — applied to ingress, so the certificate and
hostname logic is developed and tested where iteration is cheap. The cost is
accepted: the URL answers only while the shell is open during prototyping, and
D21's high ports survive only until promotion. Supersedes the high-ports-forever
reading of D21.

## Current dsh exception (2026-09-29, D42)

`dsh.hbohlen.space` remains on the system Caddy at tailnet port 443 for now.
The system route sends tokenless root requests without a dsh cookie to the
devenv-managed loopback phone-entry redirector (`dsh/phone-entry.py`,
`processes.dsh-phone-entry`), then proxies the normal dsh traffic to
`127.0.0.1:3080` (`processes.dsh-web` in `modules/dsh.nix`). This keeps the phone
URL port-less, which matters because dsh binds its session cookie to the
browser-facing authority. There is deliberately NO dsh site in
`modules/ingress.nix`: the shell Caddy serves only the two Hermes hostnames.
The route is configured in `/etc/caddy/Caddyfile` on contabo and is not yet
represented by this repo's Caddyfile. Move it with the other Caddy sites at
ingress promotion.
