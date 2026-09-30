# devenv.nix — the hermes sub-project (workstation half of the hermes-config
# effort; see docs/specs/hermes-config.md and .scratch/hermes-config/map.md).
#
# ONE MACHINE, NO TARGET: `machines.workstation` declares only a
# home-manager role with `target.host` unset. Per upstream source (R-03),
# an unset target activates in process on the current host — this is how the
# workstation gets home-manager without a NixOS host declaration, and it is
# H8's load-bearing choice.
#
# The hermes stack itself lives in ./modules/hermes.nix (ticket 06), which
# imports the upstream homeManagerModules from the locked `hermes-agent`
# input. This file stays three lines of wiring so the machine block reads as
# plumbing, not policy.
{ ... }:

{
  machines.workstation = {
    system = "x86_64-linux";
    # target.host deliberately OMITTED — activate in process (H8, R-03).
    home-manager = import ./modules/hermes.nix;
  };
}
