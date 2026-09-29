# Architectures for `hermes.hbohlen.space` — Tailnet-Only, Public DNS

## Scope
`hbohlen.space` is managed by Cloudflare DNS. We want `hermes.hbohlen.space` reachable **only** from your Tailscale tailnet, with a public DNS record existing on Cloudflare.

---

## 1. DNS Resolution Model — Public A Record + Tailnet-Only Enforcement

If `hermes.hbohlen.space` is a normal Cloudflare A record pointing at your workstation's public IP, the record itself is public. The restriction must happen at connection time.

### 1.1 Firewall rules (host-level)

Allow traffic **only** from the tailnet. Two equivalent approaches:

```bash
# nftables / iptables: allow only tailscale0 source
iptables -A INPUT -i tailscale0 -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j DROP

# or by subnet
iptables -A INPUT -s 100.64.0.0/10 -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j DROP
```

> **Tradeoff:** This is sufficient on its own if the service binds to `0.0.0.0` (all interfaces). The firewall drops everything not from `100.64.0.0/10`. It requires no daemon coordination with Tailscale.

### 1.2 Caddy `bind` to tailscale interface

Caddy can bind directly to the `tailscale0` interface so the port is **only** reachable via the tailnet. The official Tailscale plugin for Caddy documents this:

> "With Tailscale installed on a machine, Caddy can already bind to the Tailscale network interface..."
> — https://github.com/tailscale/caddy-tailscale

```caddyfile
hermes.hbohlen.space {
    bind tailscale/
    reverse_proxy localhost:8080
}
```

> "Caddy will join your Tailscale network and listen only on that network interface."
> — https://github.com/tailscale/caddy-tailscale

**Important caveat:** If you `bind tailscale/`, Caddy listens **only** on the Tailscale node. You cannot simultaneously bind `[::]` and `tailscale/` on the same port in one site block (this panics: `connection already exists`). Workaround: use two separate site blocks, or `bind tcp4/0.0.0.0 tailscale/node` (which works per issue #88).

> **Tradeoff:** Binding to tailscale means the service is unreachable on any non-tailnet interface. Combined with a firewall rule, defense in depth. The Caddy Tailscale plugin is the cleanest integration.

### 1.3 Cloudflare-side restriction (WAF, Origin Rules)

**WAF IP Access Rules** cannot help here. Tailscale `100.64.0.0/10` is a private CGNAT range — Cloudflare's edge sees the client's **public** IP, not their tailnet IP. A WAF rule on source IP would block based on public IP, not tailnet membership.

> "An IP Access rule will apply a certain action to incoming traffic based on the visitor's IP address..."
> — https://developers.cloudflare.com/waf/tools/ip-access-rules/parameters/

**Origin Rules** let you override the resolved hostname/port but do not filter by client identity. They require proxied DNS records. No tailnet-aware selector exists.

> **Tradeoff:** Cloudflare WAF/Origin Rules cannot restrict to tailnet clients. The restriction must happen at the host (firewall) or application layer (Tailscale Serve / Access).

---

## 2. Tailscale Split-Horizon DNS for a Custom Domain

### 2.1 MagicDNS scope

MagicDNS is **restricted to `*.ts.net` names only**. You cannot add arbitrary records:

> "It's not possible to add arbitrary records to MagicDNS. Subscribe to or comment on this GitHub issue for updates."
> — https://tailscale.com/docs/reference/dns-in-tailscale

> "DNS names are restricted to your tailnet's domain name (device-name.tailnet-name.ts.net)."
> — https://tailscale.com/docs/features/tailscale-serve

So MagicDNS alone **cannot** make `hermes.hbohlen.space` resolve to a `100.x` address.

### 2.2 Tailscale DNS settings (split DNS with custom nameserver)

Tailscale supports **restricted nameservers** (split DNS) for custom domains:

> "A restricted nameserver only applies to DNS queries matching a specific search domain. Using a restricted nameserver is also known as split DNS."
> — https://tailscale.com/docs/reference/dns-in-tailscale

This means you can run a **custom DNS server** (e.g. CoreDNS, dnsmasq) that resolves `*.hbohlen.space` to `100.x` addresses, and tell Tailscale to use it as a restricted nameserver for that domain. Tailnet clients will then resolve `hermes.hbohlen.space` → `100.x`, while non-tailnet clients use normal public DNS.

Documented community approach:
> "I opted to use `.tailnet` as my custom top level domain... delegated the entire zone to my coredns server."
> — https://willnorris.com/2023/tailscale-custom-domain/

There's also a purpose-built tool: https://github.com/giodamelio/tailscale-custom-domain-dns

> **Tradeoff:** Requires running an always-on DNS server (systemd service). Tailnet clients must have Tailscale DNS enabled (default). Non-tailnet clients never query your private resolver — they get whatever is in public Cloudflare DNS.

### 2.3 Cloudflare Gateway as split-horizon DNS

Cloudflare Gateway (part of Cloudflare One) supports DNS policies and local domain fallback. It can forward queries for a domain to a private resolver. However, this requires:
- Cloudflare WARP client running on the endpoint
- Gateway DNS policies configured
- A private resolver reachable from Cloudflare

This is more complex than the Tailscale DNS settings approach and ties you to the Cloudflare One ecosystem.

> **Tradeoff:** Only works with WARP client deployed. Not a pure-Tailscale solution.

---

## 3. Tailscale Serve

### What it does

> "Tailscale Serve lets you route traffic from other devices on your Tailscale network (known as a tailnet) to a local service running on your device. You can think of this as sharing the service, such as a website, with the rest of your tailnet."
> — https://tailscale.com/docs/features/tailscale-serve

### Hostname scope — **`*.ts.net` ONLY**

> "DNS names are restricted to your tailnet's domain name (device-name.tailnet-name.ts.net)."
> — https://tailscale.com/docs/features/tailscale-serve

Tailscale Serve issues Let's Encrypt certificates **only** for `*.ts.net`:

> "Tailscale creates a `*.ts.net` DNS TXT record for your nodes to complete their DNS-01 challenges."
> — https://tailscale.com/docs/how-to/set-up-https-certificates

It does **not** support custom hostnames for automatic certs. However, Tailscale PAM (Premium plan) does support custom domains for HTTP services via CNAME delegation, but that routes through Tailscale's infrastructure (Tailscale Service), not your local port directly.

### Front arbitrary local port

Yes:

> "You can proxy requests to a web server running at `http://127.0.0.1:3000` using the following command: `tailscale serve 3000`"
> — https://tailscale.com/docs/features/tailscale-serve

Supports HTTP reverse proxy, file server, directory server, static text.

### Path-based routing (`/gateway`)

Yes, via `--set-path`:

> "--set-path= Appends the specified path to the base URL for accessing the underlying service."
> — https://tailscale.com/docs/reference/tailscale-cli/serve

> "The root-level mount point would be `/` and would be matched by making a request to `https://my-node.example.ts.net/`, for example."
> — https://tailscale.com/docs/reference/tailscale-cli/serve

Also supports Layer 7 (application) endpoints for path-based routing across services:

> "Layer 7 (application) endpoints provide the most sophisticated forwarding mechanism... For example, `/api/*` requests might go to one server while `/static/*` goes to another."
> — https://tailscale.com/docs/features/tailscale-services

**Known bug:** `--set-path` can break asset loading in some single-page apps (issue #12413). Workaround: use separate ports instead of paths.

> **Tradeoff:** Serve is tailnet-only by design (correct default). But it only gives you a `*.ts.net` hostname. For a custom `hbohlen.space` hostname with Tailscale authentication headers, you need Serve + a reverse proxy (Caddy/Nginx) that adds identity headers and listens on the tailnet IP.

---

## 4. Tailscale Funnel

### What it does

> "Tailscale Funnel lets you route traffic from the broader internet to a local service running on a device in your Tailscale network (known as a tailnet). You can use it to share a local service, like a web app, for anyone to access—even if they don't use Tailscale."
> — https://tailscale.com/docs/features/tailscale-funnel

### Key facts

| Question | Answer |
|---|---|
| Custom hostnames? | No — `*.ts.net` only |
| Issues certificates? | Yes, but only for `*.ts.net` |
| Fronts arbitrary local port? | Yes |
| Path-based routing? | Yes (via `--set-path`) |
| Tailnet-only? | **No** — it's the public exposure feature |

> "If you'd like to share local services only with other devices in your tailnet, use Tailscale Serve instead."
> — https://tailscale.com/docs/features/tailscale-funnel

> **Tradeoff:** Funnel is the **opposite** of what you want. It makes a service publicly reachable. Do not use.

---

## 5. Cloudflare Tunnel (`cloudflared`)

### Can it restrict to tailnet without Cloudflare Access?

**No, not directly.** Cloudflare Tunnel itself has no concept of "tailnet member." By default, a tunnel hostname is publicly routable by anyone who resolves the DNS name. Without an Access policy, anyone can reach the origin.

To restrict access, you must use **Cloudflare Access** (part of Cloudflare One):

> "originRequest.access: ... Requires cloudflared to validate the Cloudflare Access JWT prior to proxying traffic to your origin."
> — https://developers.cloudflare.com/tunnel/reference/origin-parameters/

### Access policies that approximate tailnet-only

Tailnet IPs are private (`100.64.0.0/10`), so you cannot use Access **IP range** selectors to match tailnet clients — Access sees the client's public IP.

The closest approximation:

1. **Service tokens (machine-to-machine):** Create an Access application with a service token, and configure `originRequest.access.audTag` on the tunnel hostname. Only requests presenting the service token reach the origin. This is "tailnet-only" only if you gate the service token distribution to tailnet members.

   > "Service Auth policies allow machine-to-machine communication by authenticating requests that present service token headers. For additional security, you can restrict the token to requests from specific IP ranges..."
   > — https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/

2. **WARP + Gateway:** Require clients to connect via Cloudflare WARP, then use Gateway network policies. This is a full Zero Trust overlay, not tailnet-specific.

3. **External evaluation:** Call an external API to decide access, but this adds latency and complexity.

### Does a Tunnel require the origin to be publicly reachable?

**No.** This is the key advantage:

> "Cloudflare Tunnel provides you with a secure way to connect your resources to Cloudflare without a publicly routable IP address."
> — https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/

> "cloudflared establishes outbound connections (tunnels) between your resources and Cloudflare's global network."
> — https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/

The origin only needs outbound access to Cloudflare (port 443/7844). No inbound ports, no public IP.

> **Tradeoff:** Cloudflare Tunnel + Access is a viable architecture but introduces a dependency on Cloudflare's edge for every request. The "tailnet-only" restriction becomes "Cloudflare Access-authenticated," which is a different trust model than tailnet membership. It also requires an always-on `cloudflared` daemon.

---

## 6. Bind Only to Tailscale Interface (No Public Listener)

### Architecture

1. Service binds **only** to `tailscale0` (or `127.0.0.1` if using the Caddy Tailscale plugin).
2. Cloudflare A record for `hermes.hbohlen.space` points at the workstation's public IP.
3. Firewall drops all non-tailnet traffic on port 443.

### Is this achievable with a Cloudflare DNS record?

**Yes.** The DNS record can point at any IP, including one you own. The restriction is enforced by the firewall on the host, not by Cloudflare.

### Resolution failure mode for non-tailnet clients

A client **not** on the tailnet resolves `hermes.hbohlen.space` to the public IP. They initiate a TCP connection, but the host firewall drops the packet (source IP is not in `100.64.0.0/10`). The client sees a **timeout** — no RST, no response. The connection hangs and eventually times out.

If the service is bound **only** to `tailscale0` (not `0.0.0.0`), the OS responds with **RST** (port closed) for non-tailnet connections, because nothing is listening on the public interface. This is cleaner — faster failure for unauthorized clients.

> **Tradeoff:** This is the simplest architecture. No cloudflared, no Access, no split DNS. The hostname is "public" in DNS but unreachable. The failure mode is timeout (firewall drop) or RST (port closed). Certs work normally via Let's Encrypt HTTP-01 challenge (if you temporarily open port 80 for validation) or DNS-01 challenge (via Cloudflare API token).

---

## 7. Daemon / Service Requirements

| Architecture | Always-on daemon | Where it runs |
|---|---|---|
| **Firewall + bind tailscale0** | No daemon beyond Tailscale itself | Tailscale runs as systemd service (default pacman install). Caddy as systemd service. |
| **Split DNS (CoreDNS)** | Yes — CoreDNS or dnsmasq | systemd service. Must be reachable on tailnet IP. |
| **Tailscale Serve** | No separate daemon — `tailscale serve` runs in foreground or `--bg` | systemd service recommended (`tailscale serve -bg`). |
| **Cloudflare Tunnel** | Yes — `cloudflared` | systemd service (`cloudflared tunnel run`). |
| **Bind only to tailscale0** | No extra daemon | Tailscale systemd + Caddy systemd. |

For this workstation (Arch Linux, tailscale via pacman), Tailscale is already a systemd service. Adding `cloudflared` or `coredns` would be additional systemd units.

---

## Ranked Architectures (most → least suitable)

### 1. ✅ **Bind only to `tailscale0` + firewall drop** (Section 6)
- Simplest, pure Tailscale, no extra daemons.
- Caddy binds `tailscale/`, firewall drops non-tailnet.
- DNS record exists, public, correct TLS via DNS-01 challenge.
- **Failure mode:** RST/timeout for non-tailnet (acceptable).
- **Best fit:** This is the recommended architecture.

### 2. ✅ **Split DNS (CoreDNS) + firewall + bind tailscale0** (Section 2.2)
- Same as #1 but `hermes.hbohlen.space` resolves to `100.x` for tailnet clients, public IP for others.
- Requires running CoreDNS as a systemd service.
- Failure mode for non-tailnet: they hit the public IP, get RST/timeout.
- More elegant DNS story but more moving parts.

### 3. ⚠️ **Cloudflare Tunnel + Access Service Token** (Section 5)
- No public IP needed on origin.
- Restricts via Cloudflare Access JWT.
- Adds Cloudflare edge dependency, `cloudflared` systemd service.
- "Tailnet-only" approximated as "holds service token" — different trust model.

### 4. ⚠️ **Tailscale Serve + Caddy reverse proxy for custom hostname** (Section 3)
- Serve gives you `*.ts.net`; Caddy adds custom hostname + TLS on top of it.
- Works but the URL is `*.ts.net` for actual traffic. To serve `hermes.hbohlen.space`, you still need Caddy listening on the tailnet IP (back to architecture #1).

### 5. ❌ **Tailscale Funnel** (Section 4)
- Public exposure. Wrong direction. Do not use.

---

## Recommendation

For `hermes.hbohlen.space` on your Arch workstation:

1. Install Caddy via pacman.
2. Configure `bind tailscale/` in the Caddy site block.
3. Set up `iptables`/`nftables` to drop port 443 from non-tailnet sources (defense in depth).
4. Use Cloudflare DNS-01 challenge for Let's Encrypt certs (Caddy's `tls` directive with Cloudflare API token, or `lego`).
5. Keep the Cloudflare A record pointing at the public IP — it's needed for the DNS-01 challenge callback and for the hostname to "exist."

No extra daemons beyond Tailscale and Caddy. No Cloudflare Access subscription. No split DNS server.
