# devenv.nix — the netcup HOST, declared as a devenv Machine (devenv 2.4+).
#
# One file, two consumers: `devenv shell` for the workstation half and
# `devenv machines install|deploy` for the host half. The workstation half is
# deliberately empty for this milestone — every package added to `packages` is
# one more thing between us and a first boot, and none of them help a host
# partition its disk.
#
# Use `bin/devenv` (pinned 2.4.0), NEVER bare `devenv`: the global profile
# binary is 2.2.2 and has no `machines` subcommand at all. See bin/devenv.
{
  machines.netcup = {
    # What sets nixpkgs.hostPlatform. Devenv builds its own module list
    # (hostPlatform → disko.nixosModules.disko → its internal recovery + facts
    # modules → this module) and never calls an assembler function of ours, so
    # there is nothing to inherit from.
    system = "x86_64-linux";

    # ROOT SSH IS A HARD REQUIREMENT of `devenv machines install` and `deploy`,
    # not a preference — measured on the previous build: a config with
    # PermitRootLogin = "no" and no root key yields installCheck.hasRootAuth =
    # false, which Machines cannot install. The freshly imaged target already
    # authorizes the vault identity for root; ./hosts/netcup/default.nix is the
    # post-install half of the same posture, key-only.
    #
    # Closing root login is the HARDENING change's problem, and it will also
    # close the routine deploy path — that trade is named in the change's
    # design, not decided here.
    target.host = "root@152.53.92.126";

    # WHICH IDENTITY THE INSTALLER/ACTIVATOR USES. ssh's default lookup would
    # offer this workstation's own ~/.ssh/id_ed25519, which the target does NOT
    # authorize — the host trusts the 1Password `dev` vault key only. The
    # materialized vault key therefore has to be named explicitly.
    #
    # This is a WORKSTATION-LOCAL path (the key is `op inject`ed per use; see
    # docs/install-netcup.md) — it is not a fact about the host, and it must be
    # re-materialized on any other workstation that runs this.
    target.sshOpts = [
      "-i"
      "/home/hbohlen/.ssh/id_ed25519-op-dev"
      "-o"
      "IdentitiesOnly=yes"
    ];

    # hardware.nix is written by hand, not measured. disko derives every
    # fileSystems entry, and the only hardware facts this QEMU/KVM guest needs
    # are the VirtIO initrd modules (the previous BIOS-era deployment timed out
    # waiting for /dev/vda precisely because initrd lacked them).
    #
    # A null facter keeps the nixos-facter-modules input out of the graph
    # entirely. Switching to a generated facter report later is a change in
    # kind — measured hardware entering the configuration — not a toggle.
    hardware.facter = null;

    # WHERE THE TAILNET AUTH KEY GOES, and the reason a secretspec manifest is in
    # the tree at all. `install.secrets` is written AFTER nixos-install and
    # BEFORE reboot, so a re-image enrolls the host on its first boot with no
    # operator in the loop. `deploy` does NOT refresh these files — there is no
    # deploy-side equivalent — which is why the already-installed host's path is
    # populated once by scripts/tailnet-enroll.sh instead.
    #
    # The attribute name must equal services.tailscale.authKeyFile in
    # hosts/netcup/tailnet.nix. It is a STRING, never a Nix path literal: a path
    # literal copies its contents into the world-readable Nix store. The value
    # never enters the store, and scripts/tailnet-preflight.sh proves it.
    #
    # `owner` is numeric because the installer cannot look up users in the system
    # it is installing into.
    install.secrets."/var/lib/tailscale/authkey" = {
      secret = "TS_AUTH_KEY";
      owner = "0:0";
      mode = "0600";
    };

    nixos =
      { ... }:
      {
        imports = [ ./hosts/netcup/default.nix ];

        # Set here, not in the host file: the hostname is the declaration's
        # business in this layout, the same way devenv owns hostPlatform.
        networking.hostName = "netcup";
      };
  };
}
