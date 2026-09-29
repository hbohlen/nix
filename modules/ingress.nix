# modules/ingress.nix — ticket 06: the shell's Caddy, prototype ingress.
#
# D15: the reverse proxy runs HERE, inside the devenv shell as a `process`,
# while the ingress is a prototype. It promotes to netcup's machine layer as
# part of the D8 deploy (ADR 0002). Cost accepted: the URL answers only while
# the shell is open.
#
# D21: the shell Caddy COEXISTS with the system one. The system caddy.service
# owns 100.115.197.61:443 (measured live), so this process binds HIGH ports:
#   9443  dashboard  -> 127.0.0.1:9119
#   9444  gateway    -> 127.0.0.1:8644 (webhook) + 8642 (api_server)
#   9445  dsh        -> 127.0.0.1:3080 (the declared dsh web instance)
# All three bind 100.115.197.61 (tailscale0) ONLY: a non-tailnet client has no
# route to that address, which is the research's ranked-first architecture.
# No firewall change is made: the system Caddy already owns 443 and this
# process adds no new broadly-bound listener.
#
# D22: cloudflared is NOT in this design. The DNS-01 challenge talks to
# Cloudflare's API directly.
#
# THE TOKEN (ADR 0007): CF_API_TOKEN never becomes a Nix env entry or store
# content. It is resolved at process start from the vault item
# CLOUDFLARE_API_TOKEN (field `token` — measured: the `credential` field is
# empty) through `op read`, and passed to Caddy in its process
# environment only. Caddy reads `{env.CF_API_TOKEN}` from there.
# (The ticket text says `secretspec run`; measured, the secret is NOT in the
# manifest, so the ticket's mechanism cannot resolve it — see the process
# block below. The ADR's invariant — vault, never store — is what holds.)
#
# KNOWN GAP, MEASURED 2026-09-29: nothing listens on 127.0.0.1:8644/8642 —
# the running hermes-gateway.service has the webhook and api_server adapters
# disabled in ~/.hermes/config.yaml. The gateway site answers 502 until those
# adapters are enabled. Enabling them is a change to ~/.hermes, outside this
# repo; recorded here and in the ticket, not silently done.
#
# DNS: hermes-gateway.hbohlen.space already resolves to this machine through
# the wildcard. hermes.hbohlen.space still carries an A record to tailnet node
# `zepyhrus` (offline). Repointing it is an operator step in Cloudflare's
# dashboard, not code, and is recorded in the ticket.
#
# dsh.hbohlen.space DID carry an A record to the same offline node and was
# repointed to 100.115.197.61 on 2026-09-29 (DNS-only, TTL 300, previous value
# 100.87.45.48) — without it the site below answers nothing, because a specific
# record outranks the wildcard. The change is not code and cannot be expressed
# here; it is recorded in docs/dsh-web-endpoint.md and in the ticket.
{ pkgs, lib, config, ... }:

let
  # Stock Caddy cannot do Cloudflare DNS-01: DNS providers are Go plugins
  # compiled in at build time (docs/research/caddy-wildcard-cloudflare-dns01.md).
  # `pkgs.caddy.withPlugins` (nixpkgs PR #358586) is the supported route.
  caddy = pkgs.caddy.withPlugins {
    # v0.2.4 accepts current Cloudflare `cfut_` API tokens. Older plugin
    # releases reject these valid 54-character tokens before any API request.
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-dQvk6ezY6TQ1J7PjhCXnThF/SqVgPwBO8/RXzHCY+js=";
  };

  tailnetIp = "100.115.197.61";

  # THE SUCCESSOR CADDYFILE (D24, ADR 0002). Written to the shell's runtime
  # dir, never to /etc and never into the store: it is generated here so it
  # cannot drift from this module.
  caddyfile = pkgs.writeText "Caddyfile" ''
    {
      # 2019 is TAKEN by the system caddy.service (measured live); the shell
      # admin endpoint moves aside. D21: coexistence.
      admin localhost:20190
      auto_https disable_redirects
    }

    (tailnet_tls) {
      bind ${tailnetIp}
      tls {
        dns cloudflare {env.CF_API_TOKEN}
      }
    }

    # Dashboard. hermes.hbohlen.space still A-records to the offline
    # `zepyhrus`; until it is repointed, the dashboard is also reachable at
    # hermes-gateway below. Both names get exact-name certs via DNS-01 —
    # HTTP-01 cannot issue for a name that does not route here (D16).
    https://hermes.hbohlen.space:9443 {
      import tailnet_tls
      reverse_proxy 127.0.0.1:9119 {
        # Hermes Dashboard accepts only its loopback listener as the upstream
        # Host header. Keep the public request host at the TLS edge.
        header_up Host 127.0.0.1:9119
      }
    }

    # Gateway. The webhook adapter (8644) and api_server (8642) register
    # absolute routes, so the research verdict is root-of-own-hostname, not a
    # subpath of the dashboard.
    https://hermes-gateway.hbohlen.space:9444 {
      import tailnet_tls
      handle /v1/* {
        reverse_proxy 127.0.0.1:8642
      }
      handle {
        reverse_proxy 127.0.0.1:8644
      }
    }

    # dsh, THE DECLARED WEB INSTANCE (modules/dsh.nix).
    #
    # THE PORT ANSWER (ticket 06's open question): 9445. The system caddy owns
    # the tailnet IP's 443 until promotion, so the repo-owned site takes a high
    # port. D24 still holds — this Caddyfile is the successor of
    # /etc/caddy/Caddyfile, and the site moves to 443 at the D8 promotion.
    #
    # Intermediately, https://dsh.hbohlen.space (no port) is served by the SYSTEM
    # caddy's `*.hbohlen.space` block, which is not in this repo. That is the
    # recorded interim, not a claim of ownership: the repo declares :9445, and
    # docs/dsh-web-endpoint.md says which URL is which.
    #
    # NO `header_up Host` HERE, AND THAT IS LOAD-BEARING. dsh's /api fence
    # compares the Host authority, and its session cookie is authority-bound:
    # a rewrite to 127.0.0.1:3080 fails the fence with 403 and mints a cookie
    # no browser sends back to the domain. Caddy preserves the incoming Host by
    # default (measured: a forged Host through this site gets 403, which proves
    # the original authority reaches dsh).
    https://dsh.hbohlen.space:9445 {
      import tailnet_tls
      reverse_proxy 127.0.0.1:3080
    }
  '';
in
{
  # The Caddy with plugins must be the caddy this process runs.
  packages = [ caddy ];

  processes.caddy =
    let
      # secretspec resolves EVERY default-profile secret it can (measured via
      # `machines info`); CLOUDFLARE_API_TOKEN is likewise NOT in the manifest
      # (measured: `secretspec get` fails with "not found", `secretspec check`
      # sees only GH_TOKEN + TS_AUTH_KEY). The value EXISTS in the vault item
      # CLOUDFLARE_API_TOKEN, field `token` (measured). Adding it to the
      # manifest would put it on EVERY `devenv machines` path — the cost that
      # file's header already documents and resists. So the script reads the
      # item straight from `op`, using the same service-account token and
      # provider the manifest's [providers.dev] names.
      startCaddy = pkgs.writeShellScript "caddy-shell-ingress" ''
        set -euo pipefail
        export CF_API_TOKEN="$(${pkgs._1password-cli}/bin/op read op://dev/CLOUDFLARE_API_TOKEN/token)"
        exec ${caddy}/bin/caddy run --config ${caddyfile} --adapter caddyfile
      '';
    in
    {
      exec = "${startCaddy}";
    };

  # The dashboard is the ingress's first upstream; start it beside Caddy so
  # the prototype is one `devenv shell` away from end-to-end. --no-open: an
  # agent has no browser to open.
  processes.hermes-dashboard = {
    exec = "${pkgs.writeShellScript "hermes-dashboard" ''
      exec hermes dashboard --host 127.0.0.1 --port 9119 --no-open
    ''}";
  };

  # Smoke test: the process tree is up, and the sites answer THROUGH the
  # tailnet bind. Run by hand inside the shell; not wired into `tests` (the
  # smoke test in modules/shell.nix) because it needs the vault and the
  # tailnet up to pass.
  tasks."ingress:smoke" = {
    exec = ''
      for port in 9443 9444; do
        test -n "$(ss -tln | grep ${tailnetIp}:$port)" || {
          echo "ingress not listening on ${tailnetIp}:$port"; exit 1;
        }
      done
      echo "ingress smoke ok: both sites bound on the tailnet address"
    '';
  };
}
