# Caddy + wildcard `*.hbohlen.space` via Cloudflare DNS-01 on Nix

Research date: 2026-09-28. Workspace context: `hbohlen.space` is on
Cloudflare; the host is an Arch Linux workstation managed through a
devenv/NixOS-style flake at `/home/hbohlen/nix`; the Cloudflare API token
lives in the 1Password `dev` vault; a `secretspec.toml` at the repo root
already integrates 1Password as a secret provider.

---

## 1. Does stock `caddy` support Cloudflare DNS-01?

**Confirmed: No.** The stock `caddy` binary ships with DNS-01 support as a
framework but with **zero DNS-provider modules compiled in**. Every DNS
provider is a third-party Go plugin that must be linked at compile time.

From the Caddy docs on TLS/DNS modules:

> "DNS provider modules are plugins which extend Caddy's JSON configuration
> structure."
> — <https://caddyserver.com/docs/modules/tls.dns>

From the `xcaddy` README (the official tool for building Caddy with plugins):

> "xcaddy - Custom Caddy Builder. This command line tool and associated Go
> package makes it easy to make custom builds of the Caddy Web Server. It is
> used heavily by Caddy plugin developers as well as anyone who wishes to make
> custom caddy binaries (with or without plugins)."
> — <https://github.com/caddyserver/xcaddy>

The upstream build-your-own docs at
<https://caddyserver.com/docs/build> state:

> "Caddy's third-party plugins are installed by adding them as import in
> cmd/caddy/main.go and compiling caddy. This can be done either using the
> xcaddy utility ... or by creating a main.go file with the import and compiling
> with go build manually."

The `Ramblurr/nixos-caddy` flake says the same thing plainly:

> "The xcaddy utility is not suited for deployment on NixOS where a sandboxed,
> reproducible build is required. This flake compiles caddy from a custom
> main.go file as outlined above, currently only adding the cloudflare dns
> plugin."
> — <https://github.com/Ramblurr/nixos-caddy>

**Bottom line:** to use `dns cloudflare` in a Caddyfile or JSON config, the
binary **must** be built with the `github.com/caddy-dns/cloudflare` module.

---

## 2. Obtaining a Caddy build WITH `caddy-dns/cloudflare` on Nix

### 2a. `caddy.withPlugins` (Nixpkgs — recommended, now merged)

Merged in NixOS/nixpkgs PR [#358586](https://github.com/NixOS/nixpkgs/pull/358586).
Available on `nixos-unstable`. This is a `passthru` on the `caddy` package
that invokes `xcaddy` to compile a binary with the listed plugins, then vendors
the result deterministically.

Release-note excerpt (verbatim):

> "Caddy can now be built with plugins by using `caddy.withPlugins`, a
> `passthru` function that accepts an attribute set as a parameter. The
> `plugins` argument represents a list of Caddy plugins, with each Caddy plugin
> being a versioned module. The `hash` argument represents the `vendorHash` of
> the resulting Caddy source code with the plugins added."

**Concrete NixOS module config:**

```nix
services.caddy = {
  enable = true;
  package = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.2-0.20250724223520-f589a18c0f5d" ];
    hash = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="; # fill from first-build error
  };
  ...
};
```

To discover the hash: set `hash = lib.fakeHash;` (or any placeholder), run the
build, and Nix prints the correct sha256.

### 2b. Overriding/deriving manually (if `withPlugins` is unavailable)

On an older Nixpkgs channel that lacks `withPlugins`, replicate it with a
custom derivation:

```nix
{ lib, stdenv, go, xcaddy, cacert, git, caddy }:

{ plugins, hash ? lib.fakeHash }:

let
  pluginsSorted = lib.sort lib.lessThan plugins;
  pluginsList = lib.concatMapStrings (plugin: "${plugin}-") pluginsSorted;
  pluginsHash = builtins.hashString "md5" pluginsList;
  withArgs = lib.concatMapStrings (plugin: "--with ${plugin} ") pluginsSorted;
in
caddy.overrideAttrs (finalAttrs: prevAttrs: {
  vendorHash = null;
  subPackages = [ "." ];

  src = stdenv.mkDerivation {
    pname = "caddy-src-with-plugins-${pluginsHash}";
    version = finalAttrs.version;

    nativeBuildInputs = [ go xcaddy cacert git ];
    dontUnpack = true;

    buildPhase = ''
      export GOCACHE=$TMPDIR/go-cache
      export GOPATH="$TMPDIR/go"
      XCADDY_SKIP_BUILD=1 TMPDIR="$PWD" xcaddy build v${finalAttrs.version} ${withArgs}
      (cd buildenv* && go mod vendor)
    '';

    installPhase = ''mv buildenv* $out'';

    outputHashMode = "recursive";
    outputHash = hash;
    outputHashAlgo = "sha256";
  };
})
```

Usage is identical to `caddy.withPlugins`.

### 2c. Pre-built community flakes

- `Ramblurr/nixos-caddy` — hardcodes the Cloudflare plugin, produces a
  `caddy` package with it baked in.
  <https://github.com/Ramblurr/nixos-caddy>
- `UseTheFork/nixos-caddy-cloudflare` — same idea.
  <https://github.com/UseTheFork/nixos-caddy-cloudflare>

These drift from nixpkgs' Caddy version and don't carry the `withPlugins`
ergonomics; prefer `withPlugins` if your channel is recent enough.

### 2d. What the `services.caddy` NixOS module needs

The module's `package` option accepts any derivation and defaults to
`pkgs.caddy`:

```nix
# From nixos/modules/services/web-servers/caddy/default.nix:
package = mkPackageOption pkgs "caddy" { };
```

The systemd unit `${cfg.package}/bin/caddy run --config ...` uses it directly.
So setting `package = pkgs.caddy.withPlugins { ... };` is all that's needed
to switch the running binary.

---

## 3. Alternative certificate paths that need NO Caddy plugin

### 3a. Let's Encrypt HTTP-01

**Does NOT work for wildcards.** State plainly: the ACME spec
(RFC 8555 §8.3 "Issuing With Certificates with Wildcard Subject") requires
DNS-01 for wildcard names. Let's Encrypt's Boulder implementation enforces this.
HTTP-01 only validates exact-name certs.

Source: <https://letsencrypt.org/docs/challenge-types/> —
"HTTP-01 challenge ... can't be used for wildcard certificates. Use DNS-01."

For non-wildcard names (`hermes.hbohlen.space`), HTTP-01 works fine and needs
no plugin — stock Caddy handles it. But it **cannot** issue `*.hbohlen.space`.

### 3b. Cloudflare Origin CA certificates

A private CA run by Cloudflare that issues certs valid up to 15 years
(5 475 days) for `*.hbohlen.space`.

**Limitations:**

- **Trust store:** Origin CA certs are trusted **only by Cloudflare's edge
  servers**, not by public root stores (Mozilla, Microsoft, Apple, etc.). If a
  client connects to your origin *without going through Cloudflare's proxy*,
  it will see an untrusted-cert error. This is fatal for a tailnet-only
  deployment where the browser talks to your Caddy directly — no Cloudflare
  edge in the path.
- **Expiry:** configurable 7 / 30 / 90 / 365 / 730 / 1095 / 5 475 days.
  Cloudflare docs warn: "Cloudflare does not currently send expiration
  notifications for origin CA certificates. If you rely on long-lived origin CA
  certificates, track their expiration in your own certificate inventory or
  monitoring system."
  — <https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/>
- **Revocation:** revokable from the Cloudflare dashboard.
- **Wildcard support:** `*.example.com` is allowed (single-level prefix only;
  `*.*.example.com` is rejected).

**Verdict for this host:** unusable if the browser reaches Caddy over the
tailnet without Cloudflare proxying — which is the assumed topology. Use only
if you put Cloudflare's proxy (orange cloud) in front.

### 3c. `tls internal` — Caddy's built-in CA

Stock Caddy can serve HTTPS with certificates from its own locally-trusted CA:

```caddyfile
hermes.hbohlen.space {
  tls internal
  reverse_proxy localhost:8080
}
```

**Tradeoffs:**

- Caddy generates a self-signed root CA and tries to install it into the
  local trust store ("Caddy Local Authority"). Browsers on that machine trust
  it after that one-time install.
- **Other machines on the tailnet do NOT trust it.** Every tailnet peer sees a
  self-signed-cert warning unless you manually install Caddy's root CA on each
  of them.
- Caddy docs are explicit: "Local HTTPS does not use ACME nor does it perform
  any DNS validation. It works only on the local machine and is trusted only
  where the CA's root certificate is installed." And: "Ultimately, if you are
  relying on internal PKI, it is the system administrator's responsibility to
  ensure Caddy's root CA is properly added to the necessary trust stores."
  — <https://caddyserver.com/docs/automatic-https>
- The root CA's leaf validity is short (hours by default for `internal` issuer),
  renewed locally.

**Verdict:** works for a single-workstation dev box; wrong for serving multiple
tailnet peers who expect normal browser trust.

### 3d. `lego` or `acme.sh` for DNS-01 out of band → hand cert to Caddy

Run a separate ACME client that speaks Cloudflare DNS-01 itself, writes the
cert to disk, and reloads Caddy. Caddy only serves the pre-obtained cert; it
never speaks ACME itself.

**`lego` example** (from the author's blog, adapted):

```ini
# systemd timer + service
Exec=run --accept-tos \
  --dns cloudflare \
  --path /certificates \
  -d '*.hbohlen.space' \
  -d 'hbohlen.space'
ExecStartPost=/usr/bin/caddy reload --config=/etc/caddy/Caddyfile
```

Renewal: a timer runs daily; `lego renew` re-issues when < N days remain
(LE's default lifetime is 90 days; renewal window 1/3). The `ExecStartPost`
reload picks up the new cert only if the files changed.

**`acme.sh` example:**

```bash
export CF_Token="..."
acme.sh --issue --dns dns_cf -d '*.hbohlen.space' -d 'hbohlen.space'
acme.sh --install-cert -d '*.hbohlen.space' \
  --key-file /etc/caddy/certs/key.pem \
  --fullchain-file /etc/caddy/certs/cert.pem \
  --reloadcmd "systemctl reload caddy"
```

`acme.sh` installs its own cron (every 30 days) and calls the `--reloadcmd`
only on actual renewal.

**Tradeoffs vs Caddy-built-in DNS-01:**

- No need to compile a custom Caddy binary. Stock Nixpkgs `caddy` works.
- One more moving part (a separate timer/renewal script + hook + filesystem
  paths to get right).
- Certificate location is fixed in the Caddyfile
  (`tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem`); dynamic SAN
  changes mean re-issuing and reloading manually.
- Failure modes: if the renewal script fails, the existing cert keeps being
  served until it expires — there is no Caddy-side retry across issuers.
  You must monitor the script's exit code / logs separately.

---

## 4. Cloudflare API token scope for DNS-01

The `caddy-dns/cloudflare` module README states (verbatim):

> "Single API Token (Recommended)
> **API Token:** `Zone.Zone:Read` and `Zone.DNS:Edit` permissions for the
> domain(s) you're managing with Caddy."
> — <https://github.com/caddy-dns/cloudflare>

The deprecated split-token form:
- Zone token: `Zone.Zone:Read`
- DNS token: `Zone.DNS:Edit`

Cloudflare's own permission docs confirm the exact strings. From
<https://developers.cloudflare.com/fundamentals/api/reference/permissions/>:

| Permission key | Display name | Access |
|---|---|---|
| `zone` | Zone Read / Zone Write | Zone management |
| `dns` | DNS Read / DNS Write | DNS records |

For the caddy-dns module you need **Zone:Read** (to discover the zone) and
**DNS:Write** (to create / delete the `_acme-challenge` TXT record).

When creating the token in the Cloudflare dashboard:
- Template: "Edit Zone DNS" (or custom)
- Permissions: **Zone — Zone Read** + **Zone — DNS Write**
- Zone resources: include the specific zone for `hbohlen.space` (or all zones).

**Important:** the caddy-dns module expects the token via the
`CF_API_TOKEN` environment variable or in the Caddyfile:

```caddyfile
{
  acme_dns cloudflare {env.CF_API_TOKEN}
}
```

OR for a single site:

```caddyfile
hermes.hbohlen.space {
  tls {
    dns cloudflare {env.CF_API_TOKEN}
  }
}
```

---

## 5. Renewal behavior for each path

| Path | Renewal mechanism | What happens on failure |
|---|---|---|
| **Stock Caddy + HTTP-01 (non-wildcard)** | Background renewal via `certmagic`, 1/3 lifetime window. Exponential backoff, max 1 day between attempts, up to 30 days. Falls back to ZeroSSL if LE fails. | First failing handshake triggers retry. Continues serving the current cert while retrying. If expiry passes, certmagic still serves the expired cert (it prefers a known expired cert over no cert, to surface the problem in the browser). See <https://github.com/caddyserver/certmagic/issues/246> for the deliberate-design rationale. |
| **Caddy + DNS-01 with `caddy-dns/cloudflare`** | Same certmagic background renewal; identical backoff and LE→ZeroSSL failover. | Same as above. |
| **lego / acme.sh (out of band)** | Systemd timer / cron runs the client; it checks remaining days and renews; post-hook reloads Caddy. | If the script errors, the old cert stays in place until its expiry. No automatic CA failover. You must monitor the timer's status (`systemctl status ...timer`, logs). An expired cert with no successful renewal → browser warning; Caddy continues serving it (expired) until reloaded with a fresh cert or stopped. |
| **Cloudflare Origin CA** | Manual / custom script; Cloudflare does not auto-renew origin CA certs. 15-year validity means renewal is rare but unmonitored — you must track expiry yourself. Cloudflare sends **no** expiry notification for origin CA certs. | On expiry: if a client reaches the origin *through Cloudflare's proxy*, Cloudflare's edge rejects the expired origin-leg cert and returns a 5xx to the client. If reached directly (tailnet), browser shows expired-cert error. |
| **`tls internal`** | Caddy renews internally, local CA. | No external dependency. Renewal cannot "fail" in the ACME sense. The local CA's own cert is long-lived; leaf certs are short-lived and reissued on the fly. |
| **HTTP-01 wildcard** | **Not applicable** — impossible. | — |

Key detail on Caddy's background renewal (from the docs, verbatim):

> "Here's what happens if there's an error obtaining or renewing a
> certificate: 1. Caddy retries once after a brief pause just in case it was a
> fluke. 2. Caddy pauses briefly, then switches to the next enabled challenge
> type. 3. After all enabled challenge types have been tried, it tries the next
> configured issuer (Let's Encrypt, ZeroSSL). 4. After all issuers have been
> tried, it backs off exponentially — Maximum of 1 day between attempts, for up
> to 30 days."
> — <https://caddyserver.com/docs/automatic-https>

A related implementation note: if renewal fails and the cert is **expired**,
certmagic holds the handshake (blocking) for up to 2 minutes trying one more
time, then serves whatever it has. This is documented as "only expired
certificates have blocking maintenance."

---

## 6. Does Caddy even need a wildcard cert on a tailnet-only host?

### The handshake contract

A browser (or any TLS client) reaching `https://hermes.hbohlen.space` sends a
ClientHello with SNI = `hermes.hbohlen.space`. The server must present a cert
whose SAN **matches that exact hostname** (or a wildcard that covers it).
The tailnet is a Layer-3 tunnel — it does not change the hostname the client
resolves. Tailscale's MagicDNS resolves `hermes.hbohlen.space` to a tailnet IP,
but the client still SNIs `hermes.hbohlen.space`, and the cert must cover it.

### Tailscale's own cert issuance — domain scope

Tailscale only issues certificates automatically for `*.ts.net` hostnames
(MagicDNS names). The docs state:

> "When Caddy gets an HTTPS request for a `*.ts.net` site, it gets the HTTPS
> certificate from the machine's local Tailscale daemon."
> — <https://tailscale.com/docs/integrations/web-servers/caddy/caddy-certificates>

Caddy's automatic HTTPS page says the same:

> "Domains ending in `.ts.net` will not be managed by Caddy. Instead, Caddy will
> automatically attempt to get these certificates at handshake-time from the
> locally-running Tailscale instance."
> — <https://caddyserver.com/docs/automatic-https>

**Tailscale does NOT issue certs for `hbohlen.space` or `*.hbohlen.space`.**
Your custom domain is outside `*.ts.net`. You must provision that cert yourself.

### SAN options

Let's Encrypt issues **one SAN per certificate** (Caddy enforces this):

> "For managed certificates, Caddy always uses 1 subject per certificate."
> — <https://caddy.community/t/is-it-normal-for-two-tls-certificates-to-be-generated-if-i-want-to-use-a-wildcard/33382>

So you cannot get a single LE cert with both `hbohlen.space` and
`*.hbohlen.space`. You have three realistic choices:

| Cert | SAN | What it covers | Issuer |
|---|---|---|---|
| A | `*.hbohlen.space` | Every current + future subdomain of hbohlen.space | LE via DNS-01 (with plugin or out-of-band) |
| B | `hermes.hbohlen.space` (and other explicit names you list) | Only the listed names; must be reissued to add a new subdomain | LE via HTTP-01 (stock Caddy) or DNS-01 |
| C | `*.hbohlen.space` | Same coverage as A | Cloudflare Origin CA (not browser-trustable for direct tailnet access) |

**Wildcard alone does NOT cover the apex domain.** A cert for
`*.hbohlen.space` does **not** match `hbohlen.space` itself (RFC 6125; the
wildcard only replaces the left-most label). If you serve the bare domain you
need a second cert or to redirect apex → www.

### Analysis: what does your cert *need* to cover?

Given the topology — Caddy reachable only over the tailnet, clients resolving
`hermes.hbohlen.space` → tailnet IP:

- The cert **must** have `hermes.hbohlen.space` (or `*.hbohlen.space`) in its SAN.
- It **must** be trusted by the browser's root store without manual installs
  on every peer → eliminates `tls internal` and Cloudflare Origin CA for
  direct access.
- Wildcard `*.hbohlen.space` is the cheapest path to "any subdomain works"
  without re-issue.

---

## Recommended path

**Use `caddy.withPlugins` on nixos-unstable to add the Cloudflare DNS-01
module, with a single Cloudflare API token scoped to Zone:Read + DNS:Write on
the `hbohlen.zone`.** This keeps everything inside Caddy's automatic HTTPS
(cert renewal, ZeroSSL failover, OCSP stapling, background maintenance) with
no external scripts, no filesystem cert juggling, and no per-peer trust
installs.

### Exact configuration

**Step 1 — Cloudflare API token.** Create a token with:
- Permissions: **Zone — Zone Read** + **Zone — DNS Write**
- Zone resources: the zone for `hbohlen.space` only.
Store the value in the 1Password `dev` vault under a label your `secretspec.toml`
resolves to the environment variable `CF_API_TOKEN`.

**Step 2 — NixOS module.**

```nix
services.caddy = {
  enable = true;

  # Build caddy with the cloudflare DNS-01 plugin.
  package = pkgs.caddy.withPlugins {
    plugins = [
      "github.com/caddy-dns/cloudflare@v0.2.2-0.20250724223520-f589a18c0f5d"
    ];
    # Fill from first build error:
    hash = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=";
  };

  # Inject the token into Caddy's environment from the resolved secret.
  # (Method depends on how secretspec exposes it here —
  #  e.g. services.caddy.environmentFile or systemd credential.)
  #
  # Example with environmentFile:
  # environmentFile = config.sops.secrets."caddy/cf_api_token".path;

  virtualHosts = {
    "hermes.hbohlen.space" = {
      extraConfig = ''
        reverse_proxy localhost:8080  # or whatever port hermes binds
      '';
    };
  };

  # The global DNS-01 issuer configuration. Wildcard names trigger
  # ACME DNS-01 automatically; no other challenge type can issue a wildcard.
  extraConfig = ''
    *.hbohlen.space {
      tls {
        dns cloudflare {env.CF_API_TOKEN}
      }
    }
  '';
};
```

Or, if you prefer a single wildcard block that also handles the apex via a
redirect:

```caddyfile
{
  email your-email@example.com
}

*.hbohlen.space {
  tls {
    dns cloudflare {env.CF_API_TOKEN}
 }

  @hermes host hermes.hbohlen.space
  reverse_proxy @hermes localhost:8080

  # other subdomains ...
}

hbohlen.space {
  redir https://hermes.hbohlen.space{uri} permanent
}
```

**Step 3 — verify.**

```bash
# Check the built binary has the plugin:
/nix/store/...-caddy-with-plugins-.../bin/caddy list-modules | grep -i dns
# Expected: dns.providers.cloudflare

# Check that the running Caddy obtained the cert:
journalctl -u caddy | grep -E "certificate renewed|new certificate"
```

### Why this path wins

- **Single moving part:** Caddy manages the full ACME + renewal lifecycle.
- **Automatic renewal with CA failover:** LE → ZeroSSL, exponential backoff,
  30-day retry window, no operator intervention under transient failures.
- **Browser-trusted without per-peer action:** LE is in every root store; no
  need to install Caddy's local CA on every tailnet peer.
- **Nix-native:** `withPlugins` produces a reproducible, sandboxed build — no
  `xcaddy` running loose on the host, no drift.
- **Covers future subdomains:** wildcard `*.hbohlen.space` means adding
  `git.hbohlen.space` or `docs.hbohlen.space` is just another virtual-host
  block — no re-issuance needed.
- **Tailnet-safe:** the cert is validated by the browser against public roots
  purely on hostname; the transport being WireGuard underneath is irrelevant
  to the trust decision.

### When to pick an alternative

- If the nixpkgs channel in use lacks `withPlugins` and you cannot update → use
  **out-of-band `lego` + `caddy reload`** (Section 3d). It is the next-simplest
  and avoids custom Caddy builds, but you own renewal monitoring.
- If the host is single-workstation only and you never serve other tailnet
  peers → **`tls internal`** is the absolute simplest (one line, no plugin, no
  secret). Wrong for any multi-device scenario.
- If you will route traffic through Cloudflare's proxy (orange cloud) rather
  than directly over the tailnet → **Cloudflare Origin CA** gives you a 15-year
  cert with no renewal burden, but only the Cloudflare edge can validate it.

---

## Sources

- <https://caddyserver.com/docs/modules/tls.dns>
- <https://github.com/caddy-dns/cloudflare>
- <https://caddyserver.com/docs/automatic-https>
- <https://caddyserver.com/docs/caddyfile/directives/tls>
- <https://github.com/caddyserver/xcaddy>
- <https://nixos.org/manual/nixpkgs/>
- <https://github.com/NixOS/nixpkgs/pull/358586> (merged `withPlugins`)
- <https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/web-servers/caddy/default.nix>
- <https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ca/caddy/package.nix>
- <https://developers.cloudflare.com/fundamentals/api/reference/permissions/>
- <https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/>
- <https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/>
- <https://tailscale.com/docs/integrations/web-servers/caddy/caddy-certificates>
- <https://go-acme.github.io/lego/>
- <https://github.com/acmesh-official/acme.sh>
- <https://github.com/Ramblurr/nixos-caddy>
- <https://github.com/caddyserver/certmagic/issues/246> (expired-cert serving
  rationale)
