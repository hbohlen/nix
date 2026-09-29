# Hermes Web Endpoints — Reverse-Proxy Routing Report

## 1. The Dashboard Web UI

**Process:** `hermes dashboard` → `hermes_cli/main_dashboard.py` → `hermes_cli/web_server.py:start_server()` (line 1370) → FastAPI app served via **uvicorn**.

**Default port:** `9119`, bind `127.0.0.1` (overridable via `--port`, `--host`).

**How started:**
```
$ hermes dashboard [--port 9119] [--host 127.0.0.1] [--no-open]
```

The `start_server()` signature (`hermes_cli/web_server.py:1370`):
```python
def start_server(
    host: str = "127.0.0.1",
    port: int = 9119,
    open_browser: bool = True,
    allow_public: bool = False,
    ...
):
```

**Server construction** (`hermes_cli/web_server.py:1138`):
```python
uvicorn.Server is driven directly (not uvicorn.run) so startup is split from ...
```
Uvicorn is configured with `proxy_headers=True` (trusted proxy-header processing) so `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Prefix` are honored behind a TLS terminator.

---

## 2. The Gateway HTTP Endpoint

**Systemd unit** (`/home/hbohlen/.config/systemd/user/hermes-gateway.service`):
```
ExecStart=/home/hbohlen/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run
Environment="HERMES_HOME=/home/hbohlen/.hermes"
Restart=always
```

**What serves it:** `hermes_cli.main gateway run` invokes `hermes_cli/subcommands/gateway.py` → `gateway.run` → `GatewayRunner`, which starts aiohttp platform adapters per the gateway config.

**Ports:** The gateway is NOT a single-port process. Each platform adapter binds its own port:
| Platform | Default Port | Config key |
|---|---|---|
| `webhook` | **8644** | `platforms.webhook.extra.port` |
| `api_server` (OpenAI-compat) | **8642** | `platforms.api_server.extra.port` |
| `feishu` | 8765 | `platforms.feishu.extra.webhook_port` |
| `msgraph_webhook` | 8646 | `platforms.msgraph_webhook.extra.port` |
| `line` | 8646 | `platforms.line.extra.port` |
| `teams` | 3978 | `platforms.teams.extra.port` |

Source: `hermes_cli/web_server_gateway.py:48-53` and `gateway/platforms/api_server.py:201`, `gateway/platforms/webhook.py:57`.

**URL paths served** (all rooted at `/`, absolute):
| Path | Method | Source |
|---|---|---|
| `/health`, `/health/detailed` | GET | all adapters |
| `/webhooks/{route_name}` | POST | `gateway/platforms/webhook.py:226` |
| `/p/{profile}/webhooks/{route_name}` | POST | `gateway/platforms/webhook.py:228` |
| `/p/{profile}/{tail:.*}` | * | `gateway/platforms/webhook.py:231` |
| `/v1/chat/completions` | POST | `gateway/platforms/api_server.py:80` |
| `/v1/responses` | POST | `gateway/platforms/api_server.py:82` |
| `/v1/models` | GET | `gateway/platforms/api_server.py:79` |
| `/v1/runs/{run_id}/events` | GET (SSE) | `gateway/platforms/api_server.py:84` |
| `/api/sessions`, `/api/sessions/{id}` | GET/POST | `gateway/platforms/api_server.py:88-95` |
| `/api/sessions/{id}/chat/stream` | POST (SSE) | `gateway/platforms/api_server.py:96` |
| `/v1/browser-control/ws` | GET (WebSocket) | `gateway/platforms/api_server.py:98` |

The API server registers every route twice — once at root, once under `/p/{profile}/` (`api_server.py:3929-3933`):
```python
self._app.router.add_route(method, path, handler)
self._app.router.add_route(method, f"/p/{profile}{path}", handler)
```

---

## 3. Base-path / prefix support

### Dashboard: **YES — configurable base path**

The dashboard reads `X-Forwarded-Prefix` from the request, normalises it, and injects it as `window.__HERMES_BASE_PATH__` into served HTML. CSS `url(...)` references and asset `href`/`src` attributes are rewritten per-request.

Source: `hermes_cli/dashboard_auth/prefix.py:61-76` (`normalise_prefix`) and `hermes_cli/web_server_dashboard.py:159`:
```python
f'window.__HERMES_BASE_PATH__="{prefix}";'
```
Asset rewriting (`web_server_dashboard.py:165-167`):
```python
for attr in ('href="/assets/', 'src="/assets/', ...):
    html = html.replace(attr, attr.replace('"/', f'"{prefix}/', 1))
```

Config keys:
- `dashboard.public_url` in `config.yaml` — full public authority (scheme+host+path) for OAuth redirect_uri. Precedence: env `HERMES_DASHBOARD_PUBLIC_URL` wins over `config.yaml`.
- `HERMES_DASHBOARD_PUBLIC_URL` env var.

Docs quote (`website/docs/user-guide/features/web-dashboard.md`):
> "For deploys behind reverse proxies that don't reliably forward those headers (manual nginx setups, on-prem ingresses, custom-domain deploys with partial proxy chains), set `dashboard.public_url` (or `HERMES_DASHBOARD_PUBLIC_URL`) to the **complete public URL** the dashboard is reached at: `public_url: "https://dashboard.example.com/hermes"`"

### Gateway: **NO configurable base path**

Searched for `base_path`, `basePath`, `root_path`, `url_prefix`, `PUBLIC_URL`, `prefix` in `gateway/`. The gateway platforms register all routes at absolute `/` paths with no prefix stripping, no root_path awareness, and no equivalent config key. `NOT DOCUMENTED`.

The `/p/<profile>/` prefix is a *routing* prefix for multi-profile multiplexing, not a configurable base path — it's hardcoded in the adapter route tables.

---

## 4. Gateway at `https://hermes.hbohlen.space/gateway` — what breaks

**Caddy `handle_path /gateway/*` strips the prefix before proxying**, so the gateway sees requests at `/webhooks/foo`, `/v1/chat/completions`, etc. — the routes themselves match. However:

| Concern | Status |
|---|---|
| Route tables | ✅ Match (prefix is stripped by Caddy) |
| WebSocket upgrades | ⚠️ `browser-control/ws` at `/v1/browser-control/ws` — works if Caddy passes `Connection: Upgrade` headers. |
| SSE streaming | ⚠️ `/v1/runs/{id}/events` — works, but Caddy must not buffer SSE (use `respond` wisely or disable buffering). |
| Redirect Location headers | ⚠️ The gateway itself rarely issues 302s, but webhook OAuth flows (e.g. Feishu, MS Graph) may. The gateway generates callback URLs from its own route table at `/p/<profile>/...` — these would be wrong behind a subpath unless the gateway also knows the prefix. |
| POST bodies | ✅ Unaffected |
| CSRF / Origin checks | ❌ The gateway's `api_server` has Host/Origin validation for browser control (`_STATIC_FEATURE_FLAGS`, `browser_control`). Behind a subpath, the Origin header still matches the browser's public origin, so this works. But any `redirect_uri` construction for OAuth platform onboarding would be wrong because the gateway has no concept of the `/gateway` prefix. |

**Verdict:** `POSSIBLE-WITH-WORK` — HTTP routes will proxy fine with prefix stripping. The breakage is in **URL generation**: the gateway constructs absolute webhook callback URLs (e.g. registering a Telegram webhook with the provider, or MS Graph subscription notifications) from its own route table. Without a base_path config, those callbacks would be generated as `https://hermes.hbohlen.space/webhooks/foo` instead of `https://hermes.hbohlen.space/gateway/webhooks/foo`. There is no documented `gateway.public_url` or equivalent to fix this.

---

## 5. Dashboard at `https://hermes.hbohlen.space` (root)

**Easy — fully supported.** The dashboard is designed for exactly this. Caddy proxies all traffic to `http://127.0.0.1:9119` (prefix `/`), no path rewriting needed.

```
handle {
    reverse_proxy 127.0.0.1:9119
}
```

**`SUPPORTED`**. This is the documented deployment model.

---

## 6. WebSocket and streaming requirements

### Dashboard (port 9119)
- **WebSocket** at `/api/ws` — the embedded TUI chat (`hermes --tui` over PTY, rendered via xterm.js). Used in the "Chat" tab. Source: `website/docs/user-guide/tui.md:290`.
- Caddy directive needed:
  ```
  @websocket {
      header Connection Upgrade
      header Upgrade websocket
  }
  reverse_proxy @websocket 127.0.0.1:9119
  ```
  (Caddy v2 auto-detects WebSocket upgrades by default, but the `Upgrade` header must be forwarded.)

### Gateway (ports 8642/8644/...)
- **WebSocket** at `/v1/browser-control/ws` (browser control protocol v1).
- **SSE** at `/v1/runs/{run_id}/events` and `/api/sessions/{id}/chat/stream`.
- Caddy directives needed:
  ```
  @sse {
      path /v1/runs/*/events /api/sessions/*/chat/stream
  }
  reverse_proxy @sse {
      header_up X-Accel-Buffering no
  }
  ```
  (Nginx needs `X-Accel-Buffering no`; Caddy does not buffer SSE by default.)

---

## 7. Official reverse-proxy docs

Yes — in `website/docs/user-guide/features/web-dashboard.md`:

> "By default, the dashboard reconstructs the OAuth callback URL from the request — `X-Forwarded-Host` + `X-Forwarded-Proto` + `X-Forwarded-Prefix` (when uvicorn is configured with `proxy_headers=True`, which `start_server` enables under the gate). This works out of the box behind a reverse proxy that sets all three headers correctly."

> "For deploys behind reverse proxies that don't reliably forward those headers... set `dashboard.public_url` (or `HERMES_DASHBOARD_PUBLIC_URL`) to the complete public URL the dashboard is reached at: `public_url: 'https://dashboard.example.com/hermes'`"

And for Docker (`website/docs/user-guide/docker.md`):

> "When a reverse proxy such as Traefik or nginx runs in another container, its bridge-network address is not trusted by default. Set the dashboard's public URL and trust only that proxy's exact IP... `dashboard: { public_url: 'https://dashboard.example.com', trusted_proxies: ['172.20.0.5'] }`"

For the gateway side: `NOT DOCUMENTED`. No mention of subpath reverse-proxying the gateway in the docs.

---

## 8. Summary

| Endpoint | Subpath | Status |
|---|---|---|
| Dashboard (`hermes dashboard`) | Root `/` | ✅ **SUPPORTED** |
| Dashboard | `/hermes` (or any prefix) | ✅ **SUPPORTED** via `X-Forwarded-Prefix` / `dashboard.public_url` |
| Gateway (`hermes gateway run`) | Root `/` | ✅ Works as-is |
| Gateway | `/gateway` (subpath) | ⚠️ **POSSIBLE-WORK** — HTTP routes proxy fine with prefix stripping; WebSocket/SSE work; **webhook callback URL generation breaks** because the gateway has no base-path config. |

---

## Recommended Caddy site block

```caddy
hermes.hbohlen.space {
    # Dashboard at root — fully supported, public_url optional
    # (only needed if X-Forwarded-* headers are unreliable)
    reverse_proxy 127.0.0.1:9119 {
        # Forward X-Forwarded-* for proxy_headers=True uvicorn trust
        header_up X-Forwarded-For {http.request.remote.host}
        header_up X-Forwarded-Proto {http.request.scheme}
        header_up X-Forwarded-Host {http.request.host}
    }
}

# Gateway: only viable at root. Subpath requires prefix stripping + URL rewrite.
# If you must use /gateway, uncomment and accept that webhook callbacks will be wrong.
#
# hermes.hbohlen.space {
#     handle_path /gateway/* {
#         reverse_proxy 127.0.0.1:8644  # webhook adapter
#         # OR
#         reverse_proxy 127.0.0.1:8642  # api_server
#         uri strip_prefix /gateway
#     }
#     handle {
#         reverse_proxy 127.0.0.1:9119  # dashboard at root
#     }
# }
```

**Recommendation:** Serve the dashboard at root (works perfectly), and expose the gateway either:
1. At a **different hostname** (e.g. `gateway.hbohlen.space`) if you need webhook/API endpoints — this avoids the callback-URL generation bug.
2. At root on the same hostname on a **different port** (not Caddy-terminated).
3. If subpath is mandatory, accept that you'll need to set callback URLs manually per-platform, since the gateway won't generate them with the `/gateway` prefix.
