> Provenance: consolidated from two parallel research passes (kanban cards t_5dedd9b4 dispatcher run + delegation sa-0-7de8452d). This version keeps the deeper findings: systemd dsh-web.service discovery, the dsh-web-capture-url journal race, and the live probes.

# dsh web access surface — research digest

Card: t_5dedd9b4. Date: 2026-09-29. Machine: contabo.

Subject: the installed dsh 0.1.5-rc.1 (mise npm global) and the source checkout
at `~/projects/deepseek-harness` (fetched to `dsh-v0.2.0-rc.2` today).

Every claim below has one of three marks:

- `[code]` read from the tagged source in the checkout.
- `[measured]` produced by a live probe on this machine today.
- `[web]` read from an upstream issue, release note, or community page.

---

## Verdicts at a glance

| Question | Verdict |
|---|---|
| Token single-use? | No. One token per process, reusable until the process exits. |
| Token expiry? | None. The token dies with the process only. |
| Stored token 401s | Capture race in `dsh-web-capture-url`. It returns the previous process's token. |
| Loopback-only methods | None on 0.1.5-rc.1. One fence, authority-based. |
| Models page fails remotely | Client-side settings scope, not the fence. |
| 0.1.6 / 0.1.7 remote story | None landed. Fronting the loopback server stays unsupported. |
| Shim survives 0.1.5 -> 0.1.7 | Yes, with one routing item to verify. |

---

## 1. Launch-token lifecycle

### Generation and storage

- The token is 32 random bytes in base64url form, so 43 characters.
  `[code]` `packages/client/connection/src/browser-auth.ts`: `SECRET_BYTES = 32`,
  `processLaunchToken()`.
- One token per PROCESS. It lives in a process-wide `WeakMap` keyed on the root
  application context. A Connection reload keeps the same token. `[code]`
- dsh never writes the token to disk. `[code]` The only copy is the startup
  stdout line.
- The token is NOT single-use. `[measured]` Two exchanges of the same token both
  returned `303 See Other`. The second exchange minted a second cookie.

### Accepted exchange shape

One shape works. `[code]` `[measured]`

| Request | Result |
|---|---|
| `GET /?token=<token>` | `303`, plus `Set-Cookie` |
| Same token again | `303` again |
| `GET /index.html?token=<token>` | `401` |
| `GET /?token=a&token=b` | `401` |
| `POST /?token=<token>` | `405` |
| No token, no cookie | `401` |

The 401 body is one sentence: `[measured]`

```
dsh web authentication required; reopen the URL printed by dsh web.
```

### Cookie: the durable credential

`[measured]` on the live 3080 instance:

```
set-cookie: dsh-auth-<sha256(authority) b64url>=v1.<payload>.<hmac>;
            Max-Age=2592000; Path=/; Expires=<start + 30d>;
            HttpOnly; SameSite=Strict
```

- Lifetime: `Max-Age=2592000` seconds, so 30 days. `[measured]`
- `cookieMaxAgeDays` sets the lifetime. The default is 30 and the minimum is 1.
  `[code]` The value is the same in 0.1.5-rc.1, 0.1.7-rc.2, and 0.2.0-rc.2.
- The cookie is host-only (no `Domain` attribute), `Path=/`, `HttpOnly`, and
  `SameSite=Strict`. `[code]` `[measured]`
- The cookie has NO `Secure` attribute. Upstream does this on purpose, because
  the shipped server speaks loopback HTTP. A browser sends the cookie over
  HTTPS anyway, so the proxy path works. `[code]`
- The cookie is authority-bound. The normalized hostname plus port appear in
  the cookie NAME and in the signed payload. `[code]`
- The signing secret is the credential record
  `client-connection/browser-session` in `$DSH_HOME/.credentials.yaml`.
  `[code]` On the installed 0.1.5-rc.1 the home is `~/.dsh`.
- A cookie survives a process restart, if the secret record and the authority
  stay the same. `[code]` Deleting the record logs every browser out at the
  next Connection activation.
- A repeat visit to the token URL with a live cookie mints a NEW cookie with a
  fresh 30-day window. The token branch runs before the cookie branch. `[code]`
- Unknown cookie attributes are ignored. dsh looks up its own cookie name and
  reads no other attribute. A proxy may add attributes safely. `[code]`
- Multi-instance is safe. Two ports on one home get two different cookie names.
  `[measured]` The `127.0.0.1:3080` cookie and the `dsh.hbohlen.space` cookie
  are different values, and neither is accepted for the other authority.

### The stored-token 401 — root cause, proven

The cause is not the token lifetime. The cause is a capture race.

- The live process `1246653` printed its URL at `04:20:29`. `[measured]`
- `~/.dsh/dsh-web.url` has mtime `04:20:06`, so 23 seconds EARLIER. `[measured]`
- File token digest: `cd1caed5d722c00a`. Live token digest:
  `f8560bf0ff5e9aac`. The two values differ. `[measured]`
- `~/.local/bin/dsh-web-capture-url` runs as `ExecStartPost`. It loops 30 times
  and greps `journalctl --user -u dsh-web -n 8 | tail -1`.
- The unit writes about 3 journal lines per run. The PREVIOUS run's URL line was
  still inside the last 8 lines. The script matched that line on its first loop
  iteration and exited with the old token. `[measured]`
- Therefore the file holds the previous process's token, and that token is dead
  as soon as its process exits.

Verified fix, one line of filtering: `[measured]`

```console
INV=$(systemctl --user show -p InvocationID --value dsh-web)
journalctl --user -u dsh-web _SYSTEMD_INVOCATION_ID="$INV" --no-pager
```

This returns exactly the live URL line and nothing else.

Second, independent fix: refuse a line that predates the current start.

```console
journalctl --user -u dsh-web --since "$(systemctl --user show -p ExecMainStartTimestamp --value dsh-web)"
```

Note: `~/.local/bin/dsh-open` has the same defect. It trusts the file first, and
its fallback repeats the same stale grep.

---

## 2. Privileged and loopback-only methods

Verdict: on 0.1.5-rc.1 there are NO loopback-only API methods. The community
reports that name them are stale.

- `PRIVILEGED_METHODS` exists in `dsh-v0.1.1-rc.2`. It is ABSENT from
  `dsh-v0.1.2-rc.1` onward. It is absent in 0.1.5-rc.1, 0.1.7-rc.2, 0.2.0-rc.2,
  and master. `[code]`
- The decision note `.agents/notes/implemented/architecture/2026-08-24-browser-token-authentication.md`
  records the replacement. One uniform authentication covers every `/api`
  operation. The note explicitly rejects the "method-specific privileged list".
  `[code]`
- The only server-side fence is `isTrustedApiRequest(request, trustedHosts)` in
  `packages/client/connection/src/rpc-host.ts`. It has one call site. It returns
  401 or 403. `[code]`

`[measured]` on the live 3080 instance:

| Host header | Cookie | Result |
|---|---|---|
| `127.0.0.1:3080` | valid for that authority | fence passed |
| `dsh.hbohlen.space` | valid for that authority | fence passed |
| `evil.example.com` | valid for `dsh.hbohlen.space` | `403 forbidden` |
| any | absent or wrong authority | `401 unauthorized` |
| `dsh.hbohlen.space` + cross-site `Origin` | valid | `403 forbidden` |

So `--trusted-host` does extend the fence to settings and credential endpoints.
There is no second list.

### The residual loopback-only surface

The remaining restriction is CLIENT-side and native. It is the real blocker for
the Models page.

- `packages/client/ui-settings/src/client/index.ts`:
  `persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'` `[code]`
- `settings-mirror.ts`:
  `status: persistence === 'host' ? 'idle' : 'unavailable'` `[code]`
- A remote browser therefore reaches the terminal `unavailable` state and NEVER
  sends a settings RPC. This is the exact `settings are unavailable in this
  browser` error of discussion #4695. `[code]` `[web]`
- `ui-settings-general` registers the "open the configuration file" action only
  on loopback. `[code]`

This confirms the premise of card t_c5e0ec11. The fix must be client-side, in
the `@hbohlen/remote-settings` plugin. A `--trusted-host` change cannot fix it.

---

## 3. Did 0.1.6 / 0.1.7 land an endorsed remote story?

Verdict: no. Fronting the loopback server with a reverse proxy stays
undocumented and unsupported.

Measured, byte for byte, from 0.1.5-rc.1 to 0.2.0-rc.2:

- The web flag set is identical: `--host`, `--no-open`, `--port`,
  `--trusted-host`, `-h/--help`. No flag was added or removed. `[code]`
- `--host 0.0.0.0` is still refused, with the same message:
  `intentionally not supported yet for safety: it would expose remote code
  execution to the network; use 127.0.0.1 instead`. `[code]`
- The startup line `dsh web: <url>` and the `(LAN: ...)` suffix are unchanged.
  `[code]`
- `trustedHosts` semantics and `cookieMaxAgeDays` are unchanged. `[code]`
- The 2026-08-24 note lists "Add logout, TLS-proxy, and forwarding-header
  configuration" as REJECTED alternatives. It states that authentication "does
  not imply supported network deployment, TLS, forwarding-header
  interpretation, or proxy configuration". `[code]`
- The 0.1.7 release notes contain no remote-access or remote-auth item. `[web]`
- The 0.1.7 transport work (`2026-09-19-remote-duplex-stream`,
  `operator-peer.ts`) adds caller (Peer) identity to invocations. That is stream
  plumbing, not a remote-access feature. `[code]`
- One upstream document names a proxy: `docs/user/guide/github-review.md`. It
  asks for a TLS reverse proxy or tunnel that forwards one public URL to the
  loopback listener. It gives no authentication model. `[code]`
- No section of `docs/subsystems/web-server.md` describes remote access. `[code]`

### Community sources

- Discussion #4695 (2026-08-27, dsh 0.1.1-rc.2, nginx plus self-signed HTTPS)
  reports exactly the Models and Settings failure. `[web]`
- The accepted answer classifies the failure as the settings scope boundary, not
  as a provider or HTTPS problem. It names three safe topologies: SSH local
  forwarding, a remote observer with out-of-band settings, and a separately
  authenticated configuration service. It states that `--trusted-host` changes
  request trust and does not create a loopback capability or a user identity.
  `[web]`
- Issue #2689 and the community handbook page
  `sandbaseai.github.io/deepseek-harness-handbook/remote-settings-loopback.html`
  describe an "HTTP 403 privileged-method trust fence" as one of three failure
  modes. That framing matches the code at or below 0.1.1-rc.2. `[web]` `[code]`
  On 0.1.5-rc.1 the 403 applies only to an untrusted Host. The Settings failure
  is the client scope, not a 403.
- Treat the handbook page as a design proposal. It links request #4732, which is
  still open. Nothing has landed. `[web]`

---

## 4. Does the shim survive 0.1.5 -> 0.1.7?

Verdict: yes, with one item to verify.

Unchanged and safe:

- `dsh web` exists, and the four flags keep their names and their meanings.
- The stdout contract keeps its shape:
  `dsh web: http://127.0.0.1:<port>/?token=<43 base64url characters>`.
  The capture regex still matches.
- The exchange contract is unchanged: `GET` on `/`, one `token` parameter, `303`
  plus `Set-Cookie`.
- Cookie attributes, cookie lifetime, cookie name derivation, and the
  signing-secret record key are unchanged.
- The launch token is still per-process and never persisted.

Changed in 0.1.7, and to be checked:

- The post-exchange redirect changed from absolute `/` to document-relative
  `./`. `authenticatedUrl` no longer forces pathname `/`. `[code]`
- For a root-mounted deployment (loopback port 3080, domain at the root) the
  behavior is the same.
- For a path-prefixed proxy mount, the token URL and the redirect now stay
  inside the mount. Verify this item at switchover.
- `0.2.0-rc.2` was published today, 2026-09-29. The llm-agents pin is
  0.1.7-rc.2. Do not mix the two. `[web]`

Relevant to card t_7b6bc62d: the `@hbohlen/remote-settings` plugin declares
`peerDependencies: {"@deepseek-ai/dsh-host-webserver": ">=0.1.0-rc.6 <0.2.0"}`.
0.1.7-rc.2 satisfies the range. The host-side `webserver` route registration
surface is the same in both tags. `[code]`

---

## 5. Full `dsh web` flag inventory

### Installed 0.1.5-rc.1, from `dsh web --help` `[measured]`

```
Usage: dsh --profile web [options]

Serve the DeepSeek Harness browser UI.

Options:
  --host <host>                  bind host
  --no-open                      do not open the Web UI in the default browser
  --port <port>                  listen port; pass 0 to let the OS pick a free
                                 one
  --trusted-host <authority...>  extra authority the /api browser-trust fence
                                 accepts (host or host:port; repeatable)
  -h, --help                     show this help
```

### Latest, 0.2.0-rc.2 and master

The web app owns the same four flags plus `-h/--help`. No additions. `[code]`
Source: `packages/bundle/web-app/src/startup.ts`.

### Launcher flags, `apps/cli/src/args.ts` `[code]`

0.1.5-rc.1:

- `--profile <name>`
- `--from-default-profile <name>`
- `--patch <path>` (repeatable)
- `--dump-config`
- `--dump-default-config`
- `[args...]` positional, forwarded to the profile's app
- subcommand `plugin`, which forwards its arguments to pnpm

0.2.0-rc.2 adds `--dump-config-schema`, and gives `--profile` a `selectProfile`
parser. The `web` alias repeats `--patch`, `--dump-config`, and
`--dump-default-config`.

Other facts:

- `--dev` was deleted before 0.1.5 (note
  `2026-08-11-cmdline-seam-trim`). `[code]`
- The webserver schema accepts only `127.0.0.1` or `0.0.0.0` for `host`. The web
  app rejects `0.0.0.0` before the schema sees it. `[code]`
- `--port 0` asks the OS for a free port. The capture regex accepts any port.
  A fixed port is not required, but a random port changes the token URL at every
  start. `[code]`

---

## WARN list for card t_c5e0ec11

1. Do not carry `~/.local/bin/dsh-web-capture-url` into the declared setup. It
   returns the previous process's token by construction. Filter the journal by
   the current `InvocationID`, or read the URL from the process's own stdout.
2. `dsh-open` writes `$URL_FILE` from the same stale grep. Fix both, or drop
   both.
3. `--trusted-host` is necessary but not sufficient. The Models page needs the
   client-side settings plugin. Keep the plugin.
4. Keep the SAME authority that the operator types. The cookie binds hostname
   plus port. A cookie minted for `127.0.0.1:3080` never works for
   `dsh.hbohlen.space`. Keep `dsh.hbohlen.space` in the `--trusted-host` set.
5. The proxy must preserve the `Host` header. A rewrite to `127.0.0.1:3080`
   fails the fence with `403`.
6. The proxy must pass the cookie through unchanged. dsh ignores unknown
   attributes, but a proxy that strips `HttpOnly` or `SameSite` weakens the
   session.
7. `dsh-web.url` is dead after every restart, because the token dies with the
   process. The launch flow must fetch a fresh token. A stored token is never a
   fallback.
8. The cookie carries no `Secure` attribute. That is upstream design for loopback
   HTTP. Under HTTPS it still works. Do not expect the attribute.
9. Repo drift: `openspec/specs/dsh-web-ui/spec.md` and
   `docs/dsh-tailnet-endpoint.md` declare `harness.hbohlen.space` on netcup. The
   live service is `dsh.hbohlen.space` on contabo. The declared setup must state
   which name it serves.
10. A restart invalidates every outstanding launch URL. A stored URL is a
    one-restart-window artifact only.

---

## Method

Probe scripts, in the card workspace:

- `check-token.sh` — compares the stored token digest with the journal digests.
- `journal-window.sh` — shows the journal around the 04:20 restart.
- `probe-3080.sh` — token exchange, cookie attributes, refusal shapes.
- `probe-api.sh` — fence tests across Host, cookie, and Origin.
- `compare-tags.sh` — the browser-auth contract across three tags.

Tokens and cookies were held in shell variables only. No token was written to a
file.