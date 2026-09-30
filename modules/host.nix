# modules/host.nix — this host's measured facts, named in one place.
#
# The two tailnet facts every consumer needs (which address Caddy binds, which
# MagicDNS name this host answers to) previously lived under `ingress.*`
# because the hostname profile mechanism needs some module namespace. That made
# dsh read across the Ingress seam (`config.ingress.tailnet*`). This module
# owns them; Ingress and dsh consume. Why the facts are per-host and profile-
# selected: D50; the seam decision: ADR 0011; the survey: .scratch/dsh-endpoint.
#
# A host with no profile keeps the null defaults, and the consumers that need
# an address assert or skip — D3's portability property, unchanged.
{ lib, ... }:
{
  options.host = {
    tailnetIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This host's tailscale address, as measured by `tailscale status`.
        Set by a `profiles.hostname.<name>.module.host` block in devenv.nix.
      '';
    };

    tailnetName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This host's MagicDNS name. It differs from `networking.hostName` on
        netcup, whose node name is pinned `--hostname=nc` in
        hosts/netcup/tailnet.nix.
      '';
    };
  };
}
