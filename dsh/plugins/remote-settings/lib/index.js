// remote-settings — make the dsh Web UI settings surface usable from a
// non-loopback origin (reverse proxy, tailnet hostname, LAN address).
//
// Why this is needed
// ------------------
// The web client decides whether the settings document is writable by looking
// at its own page authority:
//
//   packages/client/connection/src/client/index.ts
//     isLoopback: transport?.ownsHost === true
//              || pageLocation === undefined
//              || isLoopbackHostname(pageLocation.hostname)
//
//   packages/client/ui/settings/src/client/index.ts
//     const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'
//
// A page reached at https://dsh.example.com is not loopback, so the settings
// mirror is created in memory mode, never sends `settings.describe`, and the
// Models page fails with "Loading the provider directory failed: settings are
// unavailable in this browser". `--trusted-host` only widens the Host/Origin
// fence on /api; it does not change this client-side scope.
//
// What this plugin does
// ---------------------
// It taps the served index.html and injects a pre-boot shim that declares the
// page as the transport owner (`ownsHost`). The client keeps using the real
// fetch/WebSocket carriers — `ownsHost` is read for that one predicate — so the
// only behavioural change is that settings use the Host document instead of an
// in-memory mirror.
//
// Scope note: this is for a single-operator deployment where the host is not
// reachable by untrusted parties (tailnet-only DNS, or a proxy that
// authenticates). It does not add authentication; dsh's own browser-session
// cookie still gates the page and every Host API route.

export const name = "remote-settings";
export const inject = ["webServer"];

const MARKER = "dsh-remote-settings-shim";

const SHIM = `<script data-plugin="${MARKER}">
(function () {
  try {
    // Already loopback (localhost / 127.0.0.0/8) -> the client answers true on
    // its own; leave the global untouched.
    var h = String(location.hostname || "");
    if (h === "localhost" || h === "[::1]" || /^127(\\.\\d{1,3}){3}$/.test(h)) return;
    var g = globalThis;
    if (g.__DSH_TRANSPORT__ === undefined) g.__DSH_TRANSPORT__ = { ownsHost: true };
    else g.__DSH_TRANSPORT__.ownsHost = true;
  } catch (err) {
    console.warn("[remote-settings] shim failed", err);
  }
})();
</script>`;

export function apply(ctx) {
  ctx.effect(() => {
    const dispose = ctx.webServer.tapIndex((html) => {
      if (html.includes(MARKER)) return html;
      return html.includes("<head>") ? html.replace("<head>", `<head>\n${SHIM}`) : `${SHIM}${html}`;
    });
    return dispose;
  }, "remote-settings: inject pre-boot ownsHost shim");
  ctx.logger.info("remote-settings: non-loopback settings shim registered");
}
