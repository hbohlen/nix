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
