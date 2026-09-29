# modules/dsh.nix — the DECLARED dsh web instance, and the ingress's upstream.
#
# WHY THIS FILE EXISTS. Measured 2026-09-29: the dsh Web UI on 127.0.0.1:3080
# was a hand-launched `systemctl --user` unit running a mise-installed dsh
# 0.1.5-rc.1, with the settings fix living only in `~/.dsh/plugins`. Nothing in
# this repository declared any of it, so "the domain works" depended on files
# nobody could reproduce from the tree. This module makes the chain a property
# of the tree: the binary (from the pinned `llm-agents` input), the profile and
# plugin wiring (carried in ./dsh), and the launch flow.
#
# WHAT THE UPSTREAM SERVES (decided, not guessed — see docs/dsh-web-endpoint.md):
#   dsh.hbohlen.space  -> 127.0.0.1:3080  (this process)
#   the site block is in ./ingress.nix, on the tailnet IP, port 9445.
#
# THREE MEASURED FACTS THAT SHAPE EVERY LINE BELOW. All from the research card
# (docs/research/dsh-web-remote-access.md in this repo):
#
#   1. THE COOKIE IS AUTHORITY-BOUND. dsh mints `dsh-auth-<hash(authority)>` for
#      the Host the browser used, and a cookie minted for `127.0.0.1:3080` is
#      never accepted for `dsh.hbohlen.space`. So the proxy MUST pass the
#      original Host through (./ingress.nix does not rewrite it), and the
#      authority the operator types must be in `--trusted-host`.
#   2. A PORT-LESS `--trusted-host` ENTRY MATCHES ANY PORT. Read in the pinned
#      source, `packages/client/connection/src/api-request-trust.ts`
#      (`isTrustedAuthority`): an entry without a port compares hostnames only.
#      That is why `dsh.hbohlen.space` alone covers both the port-less site on
#      the system caddy (443) and this repo's `:9445` site. Measured: a request
#      with `Host: dsh.hbohlen.space:9445` passes the fence (404 from the RPC
#      bridge), one with an undeclared authority gets 403.
#   3. THE LAUNCH TOKEN IS PER-PROCESS AND DIES WITH IT. The stored-token 401
#      every operator hit was a capture race in the old
#      `~/.local/bin/dsh-web-capture-url`, which grepped the last 8 journal
#      lines and matched the PREVIOUS process's URL. This module never greps a
#      shared log: the start script captures its OWN child's stdout, so the
#      file it writes cannot hold another process's token.
#
# DSH_HOME IS NOT `~/.dsh`. Two live instances must not share one home
# (upstream: workspace-session pruning and JSONL append corruption). `~/.dsh` is
# the hand-installed home the dev checkout on 3081 also uses; this instance gets
# `~/.dsh-web` and never touches the other. The home is OUTSIDE the repository on
# purpose: runtime state (sessions, storages, credentials) must not enter the
# tree, and a home inside it would need a .gitignore entry per new subdirectory.
#
# WHAT THE OPERATOR STILL OWNS. `dsh` resolves model credentials from the
# environment or `$DSH_HOME/.env`, never from this file. The declared home
# therefore starts without credentials and the Models page lists no provider
# until the operator writes them there (0600). That is deliberate: no secret may
# be committed or put in the store (ADR 0007).
{ pkgs, lib, config, inputs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  dsh = inputs.llm-agents.packages.${system}.dsh;

  # THE NODE PROBLEM, MEASURED 2026-09-29 — why this wrapper exists.
  #
  # dsh 0.1.7-rc.2 boots its host through `node-addon-require-builtin`, a native
  # addon that patches Node's internals by matching compiled getter code. Under
  # the Node the llm-agents package bundles (nixpkgs `nodejs-24.20.0`) it fails
  # at the first boot step, before any profile is read:
  #
  #   dsh: fatal uncaught exception: Error: dsh: host preparation failed:
  #   node-addon-require-builtin unsupported: Unsupported/no-getter
  #   (x64 sysv getter is not a recognized this->field accessor)
  #
  # Measured, not inferred: the same store path under nixpkgs `nodejs-22.23.2`
  # fails the same way; `NARB_BACKEND=nodeabi` fails with "No usable native
  # binding"; and `nix build github:numtide/llm-agents.nix#dsh` at HEAD yields
  # the SAME store path, so no pinned-version bump fixes it. The addon's probe
  # expects the upstream Node build's code layout, and nixpkgs builds Node from
  # source with different codegen.
  #
  # The workaround is therefore an interpreter swap, not a patch: run the
  # package's OWN entry point under the upstream Node 22 binary, fetched and
  # hash-pinned here. Measured working: with this interpreter the declared
  # 0.1.7-rc.2 boots and prints its launch URL.
  #
  # REMOVAL CONDITION: when the bundled Node no longer fails the addon's probe,
  # delete `nodeOfficial` and `dshDeclared` and run `${dsh}/bin/dsh` directly.
  nodeOfficial = pkgs.runCommand "node-official-22.23.1" { } ''
    mkdir -p $out
    ${pkgs.gnutar}/bin/tar -xJf ${pkgs.fetchurl {
      url = "https://nodejs.org/dist/v22.23.1/node-v22.23.1-linux-x64.tar.xz";
      hash = "sha256-l0npiPQ3NDt/qDLGne2CoxLkGgMRbXZnl6wU9vnu5Xg=";
    }} --strip-components=1 -C $out
  '';

  # The declared `dsh` entry point: the package's own bin.js, under the pinned
  # upstream interpreter, with the `--expose-internals` the package's own
  # wrapper passes. Exposed as `dsh` in `packages` below — the package's bundled
  # bin is deliberately NOT on PATH, because a `dsh` that cannot boot would
  # shadow the working one the operator has today.
  dshDeclared = pkgs.writeShellScriptBin "dsh" ''
    exec ${nodeOfficial}/bin/node --expose-internals \
      ${dsh}/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
  '';

  # THE PLUGIN, FROM THE TREE. It makes the Settings/Models page usable from a
  # non-loopback origin by injecting a pre-boot `ownsHost` shim into the served
  # index.html (the client's settings scope is client-side, so `--trusted-host`
  # alone is not enough). Copied here from `~/.dsh/plugins/remote-settings`,
  # which is where it lived as the only copy.
  plugin = ../dsh/plugins/remote-settings;

  # THE PROFILE OVERLAY. Same shape as the live `~/.dsh/profiles/web/package.json`
  # minus two things: the operator's extra tool packages (`@deepseek-ai/dsh-tools`,
  # `dshmarket`), which need a pnpm install and a lockfile this module does not
  # own, and the lockfile itself. `@deepseek-ai/dsh-base` and
  # `@deepseek-ai/dsh-web-app` are NOT dependencies — they ship with dsh and
  # resolve from the install anchor (measured in the pinned `loadProfile`).
  #
  # The `link:` target is the plugin's store path, which is exactly what pnpm
  # writes for a `link:` dependency — so no install step is needed and the
  # profile is complete on first boot.
  profilePackageJson = pkgs.writeText "dsh-web-profile-package.json" (builtins.toJSON {
    name = "dsh-profile-web";
    private = true;
    dependencies = {
      "@hbohlen/remote-settings" = "link:${plugin}";
    };
    dsh = {
      profile = {
        bundles = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
          "@hbohlen/remote-settings"
        ];
      };
    };
  });

  # THE PROFILE'S OWN PATCH LAYER, empty on purpose: the plugin arrives as a
  # bundle (its own cordis.patch.yml ships inside the package), and the home
  # layer `$DSH_HOME/cordis.patch.yml` stays free for the operator.
  profilePatch = pkgs.writeText "dsh-web-cordis.patch.yml" ''
    # The declared instance's profile patch layer. Empty: the remote-settings
    # plugin is loaded as a bundle, not as an insertion here.
    []
  '';

  # MATERIALIZE THE DECLARED HOME. Idempotent, and it splits the two kinds of
  # file deliberately:
  #
  #   profiles/web/package.json    — REPO-OWNED: the bundle list and the plugin
  #                                  link. Re-asserted on every start.
  #   node_modules/@hbohlen/remote-settings — REPO-OWNED symlink, refreshed.
  #   profiles/web/cordis.patch.yml — SEEDED ONCE. dsh writes its imported
  #                                  settings into this layer on the first boot
  #                                  (measured: a seeded settings.yaml becomes
  #                                  loader entries here and is renamed
  #                                  `settings.yaml.imported`), so overwriting it
  #                                  would wipe the operator's settings at every
  #                                  start.
  #   settings.yaml                — SEEDED ONCE, and never after the import.
  seedHome = pkgs.writeShellScript "dsh-web-seed" ''
    set -euo pipefail

    home="''${DSH_HOME:?DSH_HOME must be set}"
    profile="$home/profiles/web"

    install -d -m 0755 "$home" "$profile" "$profile/node_modules/@hbohlen"
    install -m 0644 ${profilePackageJson} "$profile/package.json"
    if [ ! -e "$profile/cordis.patch.yml" ]; then
      install -m 0644 ${profilePatch} "$profile/cordis.patch.yml"
    fi
    if [ ! -e "$home/settings.yaml" ] && [ ! -e "$home/settings.yaml.imported" ]; then
      install -m 0644 ${../dsh/settings.yaml} "$home/settings.yaml"
    fi
    ln -sfn ${plugin} "$profile/node_modules/@hbohlen/remote-settings"
  '';

  # THE PROCESS. `--trusted-host` carries the authority the operator types; the
  # port-less entry covers every port (fact 2 above). The tailnet and 8443 rows
  # are kept from the hand-launched unit so an operator who already uses
  # `contabo.worm-hue.ts.net` keeps working.
  #
  # THE STDOUT CAPTURE IS THE LAUNCH FLOW'S ONLY SOURCE. dsh prints the token URL
  # once at startup and never writes it to disk; `awk` tees it to
  # `$DSH_HOME/launch.url` (0600, rewritten at every start) while leaving stdout
  # intact for the process manager's log. No journal grep, no previous process's
  # token — the writer is the process itself (fact 3 above).
  startDsh = pkgs.writeShellScript "dsh-web-declared" ''
    set -euo pipefail

    export DSH_HOME="''${DSH_HOME:-$HOME/.dsh-web}"
    url_file="$DSH_HOME/launch.url"

    ${seedHome}

    umask 077
    rm -f "$url_file"

    ${dshDeclared}/bin/dsh web \
      --host 127.0.0.1 \
      --port 3080 \
      --no-open \
      --trusted-host dsh.hbohlen.space \
      --trusted-host contabo.worm-hue.ts.net \
      --trusted-host contabo.worm-hue.ts.net:8443 \
    | ${pkgs.gawk}/bin/awk -v f="$url_file" '
        { print; fflush() }
        match($0, /http:\/\/127\.0\.0\.1:3080\/\?token=[A-Za-z0-9_-]+/) {
          print substr($0, RSTART, RLENGTH) > f
          close(f)
          fflush()
        }
      '
  '';
in

{
  # The declared entry point — the llm-agents package under the pinned upstream
  # Node, NOT `${dsh}/bin/dsh`: that bin cannot boot on this host (the measured
  # addon failure in the let block above), and putting it on PATH would shadow
  # the working `dsh` the operator has today.
  packages = [ dshDeclared ];

  processes.dsh-web = {
    exec = "${startDsh}";
  };

  # THE LAUNCH FLOW (ticket item 4). A stored URL is never a fallback: the token
  # dies with its process, so this task reads the CURRENT process's own capture
  # and proves the token still exchanges before printing a domain URL.
  tasks."dsh:open" = {
    exec = ''
      set -euo pipefail

      url_file="''${DSH_HOME:-$HOME/.dsh-web}/launch.url"
      if [ ! -r "$url_file" ]; then
        echo "dsh:open: no launch URL captured yet — start the instance first:"
        echo "  devenv up dsh-web"
        exit 1
      fi

      token="$(sed -n 's#.*token=\([A-Za-z0-9_-]*\)$#\1#p' "$url_file" | tail -1)"
      if [ -z "$token" ]; then
        echo "dsh:open: $url_file holds no token (read: $(cat "$url_file"))"
        exit 1
      fi

      # Prove the token is live against the loopback listener with the authority
      # the browser will use. 303 is the only accepted exchange shape.
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
        -H 'Host: dsh.hbohlen.space:9445' \
        "http://127.0.0.1:3080/?token=$token" || true)"
      if [ "$code" != "303" ]; then
        echo "dsh:open: the captured token no longer exchanges (HTTP $code)."
        echo "  The process restarted since it was captured — restart it and retry:"
        echo "  devenv processes restart dsh-web"
        exit 1
      fi

      echo "https://dsh.hbohlen.space:9445/?token=$token"
      echo "(the port-less https://dsh.hbohlen.space is the system caddy's interim path;"
      echo " its cookie is a different authority and does not carry over)"
    '';
  };

  # The smoke test the ticket asks for, on the model of `ingress:smoke`: it
  # checks the pieces that can be checked from inside the shell, and it fails
  # loudly rather than reporting a green chain it did not see.
  tasks."dsh:smoke" = {
    exec = ''
      set -euo pipefail

      # The site under test, pinned to the tailnet address rather than left to
      # the local resolver: the point is the binding, and a cached A record must
      # not be able to turn a red chain green.
      site="https://dsh.hbohlen.space:9445"
      resolve="--resolve dsh.hbohlen.space:9445:100.115.197.61"
      url_file="''${DSH_HOME:-$HOME/.dsh-web}/launch.url"

      # 1. the process is up and loopback-only
      ${pkgs.iproute2}/bin/ss -tln | grep -q '127.0.0.1:3080' || {
        echo "dsh:smoke: nothing listening on 127.0.0.1:3080"; exit 1;
      }
      ${pkgs.iproute2}/bin/ss -tln | grep -q '0.0.0.0:3080' && {
        echo "dsh:smoke: dsh is listening on a non-loopback address"; exit 1;
      }

      # 2. the ingress site is bound on the tailnet address (modules/ingress.nix)
      ${pkgs.iproute2}/bin/ss -tln | grep -q '100.115.197.61:9445' || {
        echo "dsh:smoke: the ingress site is not bound on 100.115.197.61:9445"; exit 1;
      }

      # 3. a fresh launch URL mints a cookie for the DOMAIN authority, and the
      #    served page carries the remote-settings shim (the Models fix).
      #    The token comes from the same capture dsh:open reads — no second
      #    source, and no journal grep.
      token="$(sed -n 's#.*token=\([A-Za-z0-9_-]*\)$#\1#p' "$url_file" | tail -1)"
      test -n "$token" || { echo "dsh:smoke: no launch token captured yet"; exit 1; }

      jar="$(mktemp)"
      trap 'rm -f "$jar"' EXIT
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -c "$jar" \
        $resolve "$site/?token=$token")"
      test "$code" = "303" || { echo "dsh:smoke: token exchange through the domain returned $code"; exit 1; }

      page="$(${pkgs.curl}/bin/curl -s $resolve -b "$jar" "$site/")"
      case "$page" in
        *dsh-remote-settings-shim*) ;;
        *) echo "dsh:smoke: the served page carries no remote-settings shim"; exit 1 ;;
      esac

      # 4. THE AUTHORITY REACHED dsh UNCHANGED, and the cookie is what admits
      #    the caller. Both halves matter: the cookie minted at THIS authority
      #    is accepted (not 401) only if the Host the app saw is the same
      #    authority, and the same route without a cookie is refused. A forged
      #    Host never gets this far — Caddy has no site for it and answers
      #    itself, so the fence is tested at the app, not at the edge.
      no_cookie="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 $resolve "$site/api")"
      test "$no_cookie" = "401" || {
        echo "dsh:smoke: /api without a cookie returned $no_cookie, expected 401"; exit 1;
      }
      with_cookie="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 $resolve -b "$jar" "$site/api")"
      case "$with_cookie" in
        401|403) echo "dsh:smoke: the domain cookie was refused on /api ($with_cookie) — the Host reaching dsh is not this authority"; exit 1 ;;
      esac

      echo "dsh smoke ok: loopback upstream, tailnet site, domain cookie accepted, shim served, cookie-less /api refused"
    '';
  };
}