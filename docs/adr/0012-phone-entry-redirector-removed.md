# 0012 — Phone entry is deleted; the launch URL is the only door

Supersedes the phone-entry pieces of ADR 0002, ADR 0008 and ADR 0011. The
redirector is gone: `dsh/phone-entry.py`, the `processes.dsh-phone-entry`
declaration, the `dsh.entryPort` option, and the `@dshEntry` matcher in the
rendered Caddyfile. The dsh site is a single `@dsh` reverse proxy to the
loopback upstream (`dsh.port`, still interpolated from the surviving `dsh.*`
interface, ADR 0011). Every device — phones included — enters through the URL
`dsh:open` prints for the CURRENT process. A tokenless bare-domain visit now
answers dsh's authentication-required page, and that is the intended
behaviour, not a gap.

## Why

The redirector bought exactly one affordance: a bare-domain bookmark survives
dsh restarts, because the helper read the current process's launch capture and
redirected into a fresh token exchange. Its cost was a second loopback
listener, a second Caddy matcher whose ORDER was load-bearing, a dedicated
smoke step, and a contract that ADR 0011 had to widen its interface to serve.
Measured against actual use (2026-09-30), the affordance did not pay for the
mechanism, and the operator deleted it. Re-introducing a stable entry point is
allowed but should reopen this ADR rather than read as an omission someone
"fixed."

## What survives

- ADR 0011's interface minus one option: `dsh.port`, `dsh.home`,
  `dsh.publicName`. The host-facts seam (`host.tailnetIp` /
  `host.tailnetName`) is untouched.
- The authority-bound cookie rule and the port-less 443 site (D42): the
  deletion removes a READER of the launch capture, not the capture. The
  per-process stdout tee (`<home>/launch.url`) stays; `dsh:open` is its
  remaining consumer.
- The promotion shape (ADR 0008): netcup's shell Caddy still owns the dsh
  route behind `ingress.serveDsh`; contabo's system Caddy still serves the
  name until promotion.
- The access-log caution, re-grounded: the token no longer rides a
  `Location` header, it rides the request URI (`/?token=…`), so Caddy access
  logs that record request URIs remain forbidden.

## Consequences

- contabo's out-of-repo `/etc/caddy/Caddyfile` still carries the `@dshEntry`
  handle pointing at a now-dead upstream: retiring it is an operator step,
  the same class as the promotion steps. Until it is removed, tokenless root
  visits 502 on contabo; token URLs are unaffected.
- Bookmark semantics change: after every `dsh-web` restart, each device needs
  a fresh `dsh:open` URL. This is accepted, and it is what the sentence "the
  launch URL is the only door" means.
- `dsh:smoke` asserts one listener and no redirect; the token-exchange, shim,
  and cookie/authority assertions are unchanged, so the interface remains the
  test surface.
