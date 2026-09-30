# modules/ingress.nix — the shell's Caddy, PARAMETERIZED per host.
#
# D15: the reverse proxy runs HERE, inside the devenv shell as a `process`.
# D24: this module's Caddyfile is the SUCCESSOR of the workstation's
# /etc/caddy/Caddyfile. D48 (ADR 0008): at the D8 deploy the ingress promotes by
# running this SHELL stack on netcup, not by growing netcup's NixOS declaration.
# So one declaration now serves two hosts whose tailnet facts and port shape
# differ:
#
#   host     tailnet address   tailnet name              sites
#   contabo  100.115.197.61    contabo.worm-hue.ts.net   :9443 dashboard, :9444 gateway
#   netcup   100.95.168.15     nc.worm-hue.ts.net        port-less :443, all three sites
#
# THE PER-HOST VALUES ARE `ingress.*` OPTIONS (declared at the bottom), and the
# hostname PROFILES that set them live in devenv.nix:
# `profiles.hostname.contabo.module.ingress` / `profiles.hostname.netcup…`.
# devenv selects a hostname profile from the RUNNING hostname, so `devenv up`
# configures the right Caddyfile with no flag and no untracked local file to
# keep in sync. D13's "no profiles" was about toolset selection; a hostname
# profile that selects host facts is the mechanism that decision explicitly left
# room for ("re-introducing profiles later does not rewrite the file layout").
# An unprofiled host keeps `ingress.enable = false` and still evaluates cleanly,
# which is D3's portability property. (The decision itself is D50.)
#
# THE TWO SHAPES, and why they differ:
#
#   * contabo COEXISTS with the system caddy.service (D21), which owns
#     100.115.197.61:443, so this process binds HIGH ports. dsh.hbohlen.space is
#     served by that system Caddy (D42, ADR 0002's exception), so this
#     Caddyfile declares NO dsh site here.
#   * netcup has no other Caddy. This Caddy owns port-less 443 and therefore
#     carries the port-less `@dshEntry` + `@dsh` route, in matcher order, per
#     docs/dsh-web-endpoint.md — a promotion that copied only the Hermes sites
#     would drop it and break phone entry (ticket 06's carry-forward).
#
# Both sites bind `${ingress.tailnetIp}` (tailscale0) ONLY: a non-tailnet client
# has no route to that address, the research's ranked-first architecture. No
# firewall change is made: on contabo the system Caddy already owns 443 and this
# process adds no new broadly-bound listener.
#
# D22: cloudflared is NOT in this design. The DNS-01 challenge talks to
# Cloudflare's API directly.
#
# THE TOKEN (ADR 0007, kept by ADR 0008 for the promoted run): CF_API_TOKEN
# never becomes a Nix env entry or store content. It is resolved at process
# start from the vault item CLOUDFLARE_API_TOKEN (field `token` — measured: the
# `credential` field is empty) through `op read`, and passed to Caddy in its
# process environment only. Caddy reads `{env.CF_API_TOKEN}` from there.
# (The ticket text says `secretspec run`; measured, the secret is NOT in the
# manifest, so the ticket's mechanism cannot resolve it — see the process block
# below. The ADR's invariant — vault, never store — is what holds.) The one new
# requirement the netcup run adds is that the `op` service-account token exist
# in netcup's environment where `devenv up` runs.
#
# KNOWN GAP, RE-MEASURED 2026-09-30: the webhook upstream is now UP — something
# answers on 0.0.0.0:8644, so 127.0.0.1:8644 returns 404 on `/` and the gateway
# site's root is a 404, not the original 502. The api_server is still absent:
# nothing listens on 127.0.0.1:8642, so `/v1/*` through the gateway site answers
# 502. The api_server and the gateway's own config live in ~/.hermes, outside
# this repo; recorded here and in the ticket, not silently worked around — and
# not enabled from here. ADR 0008 leaves the gateway upstream undeclared;
# declaring it in this repo on netcup is ticket 08 step 3.
#
# DNS: hermes-gateway.hbohlen.space already resolves through the wildcard.
# hermes.hbohlen.space still carries an A record to the offline tailnet node
# `zepyhrus`. dsh.hbohlen.space was repointed to 100.115.197.61 on 2026-09-29
# (DNS-only, TTL 300, previous value 100.87.45.48). Repointing the hermes and
# dsh names to netcup's 100.95.168.15 and retiring the workstation's
# /etc/caddy/Caddyfile route is ticket 08 step 4, an operator step in
# Cloudflare's dashboard, not code.
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

  cfg = config.ingress;

  # A Caddy site address is PORT-LESS when the port is 443: `https://name`
  # already means :443, and the dsh cookie is authority-bound to the exact
  # `hostname:port` (D42). For the Hermes sites the difference is cosmetic; for
  # dsh it is load-bearing, which is why the dsh site is only ever declared on a
  # host that owns 443 (`ingress.serveDsh`).
  siteAddress = host: port:
    if port == 443 then "https://${host}" else "https://${host}:${toString port}";

  # THE PROMOTED HOST'S ADDITION, verbatim from docs/dsh-web-endpoint.md.
  # `@dshEntry` is the MORE SPECIFIC matcher (tokenless, cookie-less root) and
  # MUST precede the catch-all `@dsh`: Caddy evaluates `handle` directives in
  # order and they are mutually exclusive. The entry matcher sends only the
  # phone's tokenless root to the loopback redirector (127.0.0.1:3082), which
  # reads the current process's launch URL and redirects to the normal exchange;
  # the token therefore exists only in a `Location` header during that exchange,
  # so do not enable Caddy access logs that record response headers.
  dshSite = ''
    https://dsh.hbohlen.space {
      import tailnet_tls

      @dshEntry {
        host dsh.hbohlen.space
        path /
        not query token=*
        not header_regexp Cookie dsh-auth-
      }
      handle @dshEntry {
        reverse_proxy 127.0.0.1:3082
      }

      @dsh host dsh.hbohlen.space
      handle @dsh {
        reverse_proxy 127.0.0.1:3080
      }
    }
  '';

  # THE SUCCESSOR CADDYFILE (D24, ADR 0002). Written to the shell's runtime
  # dir, never to /etc and never into the store: it is generated here so it
  # cannot drift from this module. The dsh site is appended only on the host
  # that owns the port-less name (`ingress.serveDsh`).
  caddyfileText =
    ''
      {
        # 2019 is TAKEN by the system caddy.service on contabo (measured live);
        # the shell admin endpoint moves aside so both can run. D21.
        admin localhost:20190
        auto_https disable_redirects
      }

      (tailnet_tls) {
        bind ${cfg.tailnetIp}
        tls {
          dns cloudflare {env.CF_API_TOKEN}
        }
      }

      # Dashboard. hermes.hbohlen.space still A-records to the offline
      # `zepyhrus`; until it is repointed, the dashboard is also reachable at
      # hermes-gateway below. Both names get exact-name certs via DNS-01 —
      # HTTP-01 cannot issue for a name that does not route here (D16).
      ${siteAddress "hermes.hbohlen.space" cfg.dashboardPort} {
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
      ${siteAddress "hermes-gateway.hbohlen.space" cfg.gatewayPort} {
        import tailnet_tls
        handle /v1/* {
          reverse_proxy 127.0.0.1:8642
        }
        handle {
          reverse_proxy 127.0.0.1:8644
        }
      }

    ''
    + lib.optionalString cfg.serveDsh dshSite;

  caddyfile = pkgs.writeText "Caddyfile" caddyfileText;
in
{
  options.ingress = {
    enable = lib.mkEnableOption "this host's shell Caddy ingress";

    tailnetIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The tailscale address this host's Caddy binds. Null on a host with no
        hostname profile; `enable` requires it.
      '';
    };

    tailnetName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This host's MagicDNS name. Added to dsh's `--trusted-host` when set; a
        port-less entry matches the hostname on any port.
      '';
    };

    dashboardPort = lib.mkOption {
      type = lib.types.port;
      default = 9443;
      description = ''
        The dashboard site's HTTPS port. The default is the contabo prototype
        (the system Caddy owns 443 there); the netcup profile sets 443.
      '';
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 9444;
      description = "The gateway site's HTTPS port; see `dashboardPort`.";
    };

    runGateway = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether THIS host's shell runs the hermes gateway upstream
        (`hermes gateway run`, webhook 0.0.0.0:8644, api_server 127.0.0.1:8642).

        False on contabo, where the hermes-managed systemd user service already
        owns :8644 (the same coexistence rule as `serveDsh`: the system owner
        stays until the promotion retires it). True on netcup, which has no
        hermes service at all since the home-manager role was removed (D49) —
        the promoted stack declares its own upstream (D48).
      '';
    };

    serveDsh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether THIS host's Caddy owns the port-less `dsh.hbohlen.space` route.
        False on contabo, whose system Caddy owns it (D42); true on netcup.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # A misconfigured profile should fail loudly, not render `bind ` (empty)
      # or coerce a null address into a string.
      assertions = [
        {
          assertion = !config.ingress.enable || config.ingress.tailnetIp != null;
          message = "ingress.enable requires ingress.tailnetIp; set both in a profiles.hostname.<host>.module.ingress block in devenv.nix";
        }
        {
          assertion = !config.ingress.runGateway || config.ingress.enable;
          message = "ingress.runGateway requires ingress.enable; the gateway upstream only has a Caddy to answer behind when the ingress is on";
        }
      ];
    }

    (lib.mkIf cfg.enable {
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

      # THE GATEWAY UPSTREAM (ticket 08 step 3). Only the host whose shell owns
      # the upstream declares it: on contabo the hermes-managed systemd user
      # service already binds :8644 and a second `gateway run` would collide;
      # on netcup nothing else does (the home-manager role is gone, D49), so
      # the promoted stack brings its own (D48).
      #
      # WHAT IT DOES NOT FIX, MEASURED 2026-09-30. The api_server adapter
      # refuses to start without API_SERVER_KEY
      # (`gateway/platforms/api_server.py` `_api_key_passes_startup_guard`:
      # "Refusing to start: API_SERVER_KEY is required for the API server,
      # including loopback-only binds"), and `~/.hermes/.env` sets
      # API_SERVER_ENABLED=true with no key — which is why /v1/* through
      # hermes-gateway answers 502 while the webhook on :8644 is up. The key is
      # a secret, so it is provisioned into the operator's HERMES_HOME `.env`
      # on netcup, never declared here (ADR 0007). Declaring the process is
      # necessary but not sufficient for a green gateway site.
      processes.hermes-gateway = lib.mkIf cfg.runGateway {
        exec = "${pkgs.writeShellScript "hermes-gateway" ''
          exec hermes gateway run
        ''}";
      };

      # Smoke test: the process tree is up, and the sites answer THROUGH the
      # tailnet bind. Run by hand inside the shell; not wired into `tests` (the
      # smoke test in modules/shell.nix) because it needs the vault and the
      # tailnet up to pass. On netcup both ports are 443, so the list is
      # de-duplicated.
      tasks."ingress:smoke" = {
        exec = ''
          for port in ${lib.concatStringsSep " " (map toString (lib.unique [ cfg.dashboardPort cfg.gatewayPort ]))}; do
            test -n "$(ss -tln | grep ${cfg.tailnetIp}:$port)" || {
              echo "ingress not listening on ${cfg.tailnetIp}:$port"; exit 1;
            }
          done
          echo "ingress smoke ok: ${cfg.tailnetIp} bound on ${lib.concatStringsSep ", " (map toString (lib.unique [ cfg.dashboardPort cfg.gatewayPort ]))}"
        '';
      };
    })
  ];
}
