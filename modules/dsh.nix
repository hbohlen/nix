# modules/dsh.nix — the DECLARED dsh web instance, and the ingress's upstream.
#
# WHY THIS FILE EXISTS. Measured 2026-09-29: the dsh Web UI on 127.0.0.1:3080
# was a hand-launched `systemctl --user` unit running a mise-installed dsh
# 0.1.5-rc.1, with the settings fix living only in a user-local plugin. Nothing in
# this repository declared any of it, so "the domain works" depended on files
# nobody could reproduce from the tree. This module makes the chain a property
# of the tree: the binary (from the pinned `llm-agents` input), the profile and
# plugin wiring (carried in ./dsh), and the launch flow.
#
# WHAT THE UPSTREAM SERVES (decided, not guessed — see docs/dsh-web-endpoint.md):
#   dsh.hbohlen.space  -> 127.0.0.1:3080  (this process)
#   the Caddy that owns the name serves the port-less hostname on tailnet :443:
#   the SYSTEM Caddy on contabo (D42; outside this repo), the SHELL Caddy from
#   ./ingress.nix on the promoted netcup host (D48). This module declares only
#   the loopback upstream and the redirector, never the public site.
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
#      That is why `dsh.hbohlen.space` covers the port-less system Caddy site.
#      A port-less entry compares hostnames only; the Caddy reverse proxy keeps
#      the browser's domain authority unchanged.
#   3. THE LAUNCH TOKEN IS PER-PROCESS AND DIES WITH IT. The stored-token 401
#      every operator hit was a capture race in the old
#      `~/.local/bin/dsh-web-capture-url`, which grepped the last 8 journal
#      lines and matched the PREVIOUS process's URL. This module never greps a
#      shared log: the start script captures its OWN child's stdout, so the
#      file it writes cannot hold another process's token.
#
# DSH_HOME is `dsh/.dsh` inside this repository, selected by devenv. A separate
# home keeps this process isolated from other concurrently running dsh processes
# (upstream: workspace-session pruning and JSONL append corruption). The ignored
# directory keeps runtime state under the dsh boundary without tracking sessions,
# launch tokens, or credentials.
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

  # THE TRUSTED AUTHORITIES ARE A HOST FACT (ticket 08 step 2). The public name
  # `dsh.hbohlen.space` is the same on both machines and is always trusted. This
  # host's MagicDNS name comes from `host.tailnetName` (modules/host.nix), which
  # devenv's hostname profiles set (devenv.nix): contabo gets
  # `contabo.worm-hue.ts.net`, netcup gets `nc.worm-hue.ts.net`. A PORT-LESS
  # entry matches the hostname on ANY port (fact 2 in the header), so the old
  # explicit `:8443` companion entry was redundant — it lives on implicitly and
  # is not duplicated per host. Null (no hostname profile) simply omits the
  # tailnet entry; the public name still works.
  trustedHosts = [ "dsh.hbohlen.space" ]
    ++ lib.optional (config.host.tailnetName != null) config.host.tailnetName;
  trustedHostArgs = lib.concatMapStringsSep " " (host: "--trusted-host ${host}") trustedHosts;

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
  # alone is not enough). The plugin source is tracked under ./dsh.
  plugin = ../dsh/plugins/remote-settings;

  # THE OPENCODE-GO SESSION HEADER PLUGIN, PINNED FROM NPM. A THIRD-PARTY
  # DEPENDENCY, AND WHY IT IS HERE.
  #
  # OpenCode's Go relay (opencode.ai/zen/go) has required a stable
  # `x-opencode-session` header per conversation since 2026-09-05, for upstream
  # routing and prompt-cache affinity. Measured 2026-09-30 against the
  # operator's own key: the chat-completions route answers `400
  # {"type":"MissingSessionID"}` without the header and `200` with it. The
  # bundled client cannot supply it: `@earendil-works/pi-ai@0.85.1`'s
  # `createClient` has no path that emits `x-opencode-session` (it sends
  # `session_id` / `x-client-request-id` / `x-session-affinity`), and the
  # `opencode-go` catalog entries do not switch session affinity on. The
  # profile cannot either: `PiAiModelProfile` has no `headers` field, and
  # `dsh-llm-pi-ai`'s completion compat gate classifies
  # `sendSessionAffinityHeaders` and `sessionAffinityFormat` as `"withhold"`.
  # So a profile edit cannot fix this, which is why a host plugin is declared.
  #
  # WHAT IT DOES, STATED PLAINLY BECAUSE IT IS A MEASURED COST: it listens on
  # the `llm/stream` waterfall (present in the pinned dsh, `dsh-llm` line 2371)
  # and drives each matching adapter stream inside an `AsyncLocalStorage` whose
  # value a ONE-TIME `globalThis.fetch` PATCH reads to merge the header. It
  # leaves non-OpenCode providers, and requests that already carry the header,
  # untouched. This is the only mechanism available at 0.1.7-rc.2.
  #
  # WHY A FETCH AND NOT A RUNTIME `dsh plugin add`: `seedHome` re-asserts
  # `profiles/web/package.json` from `profilePackageJson` at every start, so an
  # installed package would be dropped from the bundle list on the next boot.
  # Pin the tarball here and the wiring is a property of the tree. The tarball is
  # unpacked rather than linked because a store path is read-only and a `.tgz` is
  # not a package root; `seedHome` unpacks it where a pnpm install would have put
  # it, and the bytes stay hash-pinned here.
  #
  # REMOVAL CONDITION: when upstream pi-ai ships `x-opencode-session` for the
  # `opencode`/`opencode-go` routes (deepseek-harness#5495,
  # earendil-works/pi#9230), delete `opencodeSessionTarball`, the unpack step in
  # `seedHome`, its dependency, its bundle entry, and this comment.
  opencodeSessionTarball = pkgs.fetchurl {
    pname = "dsh-opencode-session";
    version = "0.1.1";
    url = "https://registry.npmjs.org/dsh-opencode-session/-/dsh-opencode-session-0.1.1.tgz";
    sha256 = "1ygzpwy351jvjs9n7nvjzx61xvlrvhypg99jxf00ldsp3lqzk7ny";
  };

  # THE PROFILE OVERLAY. Same shape as the measured live web profile, minus two
  # things: extra tool packages (`@deepseek-ai/dsh-tools`,
  # `dshmarket`), which need a pnpm install and a lockfile this module does not
  # own, and the lockfile itself. `@deepseek-ai/dsh-base` and
  # `@deepseek-ai/dsh-web-app` are NOT dependencies — they ship with dsh and
  # resolve from the install anchor (measured in the pinned `loadProfile`).
  #
  # The `link:` targets are the plugins' package roots, which is exactly what
  # pnpm writes for a `link:` dependency — so no install step is needed and the
  # profile is complete on first boot. `@hbohlen/remote-settings` is a source
  # tree in this repository, so its link is the store path Nix already gives it;
  # `dsh-opencode-session` arrives as a tarball and is unpacked by `seedHome`
  # into the profile itself, so its link is the profile-local directory.
  # Bundle order is layer order: dsh's own bundles first, then the two plugins,
  # then the operator's patch layer (`cordis.patch.yml`, seeded once).
  profilePackageJson = pkgs.writeText "dsh-web-profile-package.json" (builtins.toJSON {
    name = "dsh-profile-web";
    private = true;
    dependencies = {
      "@hbohlen/remote-settings" = "link:${plugin}";
      "dsh-opencode-session" = "link:./node_modules/dsh-opencode-session";
    };
    dsh = {
      profile = {
        bundles = [
          "@deepseek-ai/dsh-base"
          "@deepseek-ai/dsh-web-app"
          "@hbohlen/remote-settings"
          "dsh-opencode-session"
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
  #                                  links. Re-asserted on every start.
  #   node_modules/@hbohlen/remote-settings — REPO-OWNED symlink, refreshed.
  #   node_modules/dsh-opencode-session     — REPO-OWNED package directory,
  #                                  REPLACED from the pinned tarball on every
  #                                  start (4 files; the tarball is the pin).
  #   profiles/web/cordis.patch.yml — SEEDED ONCE. dsh writes its imported
  #                                  settings into this layer on the first boot
  #                                  (measured: a seeded settings.yaml becomes
  #                                  loader entries here and is renamed
  #                                  `settings.yaml.imported`), so overwriting it
  #                                  would wipe the operator's settings at every
  #                                  start.
  #   settings.yaml                — SEEDED ONCE, and never after the import.
  #
  # The plugin is unpacked rather than linked because a store path is read-only
  # and a `.tgz` is not a package root; both the bundle's `package.json` and its
  # own `cordis.patch.yml` must sit under `node_modules/dsh-opencode-session`.
  # REPLACING it every start (rather than only when absent) is deliberate: the
  # version is declared here, so a bump must take effect on the next boot.
  seedHome = pkgs.writeShellScript "dsh-web-seed" ''
    set -euo pipefail

    # The unpacked plugin's modes must not depend on the caller's umask (the
    # launcher sets 077 for the launch-token file, and a store-extracted tree
    # would otherwise land mode 0600).
    umask 022

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
    rm -rf "$profile/node_modules/dsh-opencode-session"
    install -d -m 0755 "$profile/node_modules/dsh-opencode-session"
    ${pkgs.gnutar}/bin/tar -xzf ${opencodeSessionTarball} \
      --strip-components=1 -C "$profile/node_modules/dsh-opencode-session"
  '';

  # THE PROCESS. `--trusted-host` carries the authority the operator types; the
  # port-less public entry matches the browser-facing domain. The tailnet entry
  # is this host's MagicDNS name, parameterized above (ticket 08 step 2), so the
  # same declaration is correct on contabo and on netcup.
  #
  # THE STDOUT CAPTURE IS THE LAUNCH FLOW'S ONLY SOURCE. dsh prints the token URL
  # once at startup and never writes it to disk; `awk` tees it to
  # `$DSH_HOME/launch.url` (0600, rewritten at every start) while leaving stdout
  # intact for the process manager's log. No journal grep, no previous process's
  # token — the writer is the process itself (fact 3 above).
  startDsh = pkgs.writeShellScript "dsh-web-declared" ''
    set -euo pipefail

    export DSH_HOME="''${DSH_HOME:-$PWD/dsh/.dsh}"
    url_file="$DSH_HOME/launch.url"

    ${seedHome}

    umask 077
    rm -f "$url_file"

    ${dshDeclared}/bin/dsh web \
      --host 127.0.0.1 \
      --port 3080 \
      --no-open \
      ${trustedHostArgs} \
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

  # System Caddy sends only bare GET / requests to this local redirector. It
  # reads dsh's mode-0600 current launch URL and redirects the phone to the
  # normal token exchange. It does not log requests or expose a listener beyond
  # loopback; tailnet reachability remains controlled by system Caddy's bind.
  processes.dsh-phone-entry = {
    exec = ''
      exec ${pkgs.python3}/bin/python3 ${../dsh/phone-entry.py} \
        "''${DSH_HOME:-$PWD/dsh/.dsh}/launch.url"
    '';
  };

  # THE LAUNCH FLOW (ticket item 4). A stored URL is never a fallback: the token
  # dies with its process, so this task reads the CURRENT process's own capture
  # and proves the token still exchanges before printing a domain URL.
  tasks."dsh:open" = {
    exec = ''
      set -euo pipefail

      url_file="''${DSH_HOME:-$PWD/dsh/.dsh}/launch.url"
      if [ ! -r "$url_file" ]; then
        echo "dsh:open: no launch URL captured yet — start the instance first:"
        echo "  devenv up dsh-web"
        exit 1
      fi

      token="$(sed -n 's#.*token=\([A-Za-z0-9_-]*\)$#\1#p' "$url_file" | tail -1 || true)"
      if [ -z "$token" ]; then
        echo "dsh:open: $url_file holds no token (read: $(cat "$url_file"))"
        exit 1
      fi

      # Prove the token is live against the loopback listener with the authority
      # the browser will use. 303 is the only accepted exchange shape.
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
        -H 'Host: dsh.hbohlen.space' \
        "http://127.0.0.1:3080/?token=$token" || true)"
      if [ "$code" != "303" ]; then
        echo "dsh:open: the captured token no longer exchanges (HTTP $code)."
        echo "  The process restarted since it was captured — restart it and retry:"
        echo "  devenv processes restart dsh-web"
        exit 1
      fi

      echo "https://dsh.hbohlen.space/?token=$token"
    '';
  };

  # The smoke test the ticket asks for, on the model of `ingress:smoke`: it
  # checks the pieces that can be checked from inside the shell, and it fails
  # loudly rather than reporting a green chain it did not see. The tailnet
  # address is `host.tailnetIp` (modules/host.nix), so the same assertion is
  # correct on contabo and on netcup; a host with no hostname profile (null
  # address) has no tailnet site to assert and drops the task.
  tasks."dsh:smoke" = lib.mkIf (config.host.tailnetIp != null) {
    exec = ''
      set -euo pipefail

      # The site under test, pinned to the tailnet address rather than left to
      # the local resolver: the point is the binding, and a cached A record must
      # not be able to turn a red chain green.
      site="https://dsh.hbohlen.space"
      tailnet_ip="${config.host.tailnetIp}"
      resolve="--resolve dsh.hbohlen.space:443:$tailnet_ip"
      url_file="''${DSH_HOME:-$PWD/dsh/.dsh}/launch.url"

      # 1. the process is up and loopback-only
      ${pkgs.iproute2}/bin/ss -tln | grep -q '127.0.0.1:3080' || {
        echo "dsh:smoke: nothing listening on 127.0.0.1:3080"; exit 1;
      }
      ${pkgs.iproute2}/bin/ss -tln | grep -q '127.0.0.1:3082' || {
        echo "dsh:smoke: phone-entry redirector is not listening on 127.0.0.1:3082"; exit 1;
      }
      ${pkgs.iproute2}/bin/ss -tln | grep -q '0.0.0.0:3080' && {
        echo "dsh:smoke: dsh is listening on a non-loopback address"; exit 1;
      }

      # 2. the HTTPS site is bound on the tailnet address by the Caddy that owns
      #    the name: the system one on contabo, this repo's shell Caddy on the
      #    promoted netcup host.
      ${pkgs.iproute2}/bin/ss -tln | grep -q "$tailnet_ip:443" || {
        echo "dsh:smoke: Caddy is not bound on $tailnet_ip:443"; exit 1;
      }

      # 3. The token comes from the same capture dsh:open reads, so there is no
      #    second source and no journal grep.
      token="$(sed -n 's#.*token=\([A-Za-z0-9_-]*\)$#\1#p' "$url_file" | tail -1 || true)"
      test -n "$token" || { echo "dsh:smoke: no launch token captured yet"; exit 1; }

      # 4. a phone entering through the stable bare domain is redirected to
      #    the current process token without exposing that token in task output.
      entry_location="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{redirect_url}' \
        $resolve "$site/" || true)"
      test "$entry_location" = "$site/?token=$token" || {
        echo "dsh:smoke: bare domain did not redirect to the current dsh launch URL"; exit 1;
      }

      # 5. a fresh launch URL mints a cookie for the DOMAIN authority, and the
      #    served page carries the remote-settings shim (the Models fix).
      jar="$(mktemp)"
      trap 'rm -f "$jar"' EXIT
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -c "$jar" \
        $resolve "$site/?token=$token" || true)"
      test "$code" = "303" || { echo "dsh:smoke: token exchange through the domain returned $code"; exit 1; }

      page="$(${pkgs.curl}/bin/curl -s $resolve -b "$jar" "$site/" || true)"
      case "$page" in
        *dsh-remote-settings-shim*) ;;
        *) echo "dsh:smoke: the served page carries no remote-settings shim"; exit 1 ;;
      esac

      # 6. THE AUTHORITY REACHED dsh UNCHANGED, and the cookie is what admits
      #    the caller. Both halves matter: the cookie minted at THIS authority
      #    is accepted (not 401) only if the Host the app saw is the same
      #    authority, and the same route without a cookie is refused. A forged
      #    Host never gets this far — Caddy has no site for it and answers
      #    itself, so the fence is tested at the app, not at the edge.
      no_cookie="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 $resolve "$site/api" || true)"
      test "$no_cookie" = "401" || {
        echo "dsh:smoke: /api without a cookie returned ''${no_cookie:-no answer}, expected 401"; exit 1;
      }
      with_cookie="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 $resolve -b "$jar" "$site/api" || true)"
      case "$with_cookie" in
        "") echo "dsh:smoke: /api with a cookie did not answer"; exit 1 ;;
        401|403) echo "dsh:smoke: the domain cookie was refused on /api ($with_cookie) — the Host reaching dsh is not this authority"; exit 1 ;;
      esac

      echo "dsh smoke ok: loopback upstream, tailnet site, domain cookie accepted, shim served, cookie-less /api refused"
    '';
  };
}
