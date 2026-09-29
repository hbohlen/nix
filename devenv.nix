# devenv.nix — the netcup HOST, declared as a devenv Machine (devenv 2.4+).
#
# One file, two consumers: `devenv shell` for the workstation half and
# `devenv machines install|deploy` for the host half. The workstation half lives
# in ./modules/*.nix and is imported below, per D13.
#
# Use `bin/devenv` (pinned 2.4.0), NEVER bare `devenv` — on a workstation.
# The rule is workstation-only: the global profile binary there is 2.2.2 and has
# no `machines` subcommand. On this host the operator's home-manager role
# installs a bare `devenv` at the SAME 2.4.0 (hosts/netcup/operator.nix), so the
# two names agree and either works.
{
  # THE WORKSTATION HALF, split per D13: one module per tool group, imported
  # here beside the Machine declaration that is the host half. The split is not
  # cosmetic — D2 is the reason this map exists, so the shell's contents are
  # kept in named groups that each record which decision put them there.
  imports = [
    ./modules/tooling.nix # non-agent CLI tools, locked nixpkgs (D25)
    ./modules/languages.nix # runtimes, replacing mise (D14)
    ./modules/agents.nix # agent CLIs, pinned llm-agents input (D19, D25)
    ./modules/shell.nix # nu as the shell, and the token export (D26, D36)
  ];

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
    # offer the invoking machine's own ~/.ssh/id_ed25519, which the target does
    # NOT authorize — so the identity has to be named explicitly.
    #
    # THE `-i` PATH IS MACHINE-LOCAL, AND IT MEANS A DIFFERENT KEY ON EACH
    # MACHINE THAT RUNS THIS DECLARATION. On a WORKSTATION it is the 1Password
    # `dev` vault key, materialized at the moment of use, which is the only
    # identity a freshly imaged target authorizes. On the HOST it is that host's
    # own loopback key (design D4), installed there 0600: a deploy run on the
    # host targets `root@localhost`, and this declaration is what names the
    # client identity for it.
    #
    # ONE PATH, BECAUSE THE PER-INVOCATION ESCAPE HATCH IS CLOSED. `bin/devenv
    # machines deploy --help` reports `-O, --option <OPTION:TYPE> <VALUE>` with
    # supported types `string, int, float, bool, path, pkg, pkgs` — none of them
    # replaces a string list, so `sshOpts` cannot be overridden per invocation.
    # And `IdentitiesOnly=yes` below disables ssh's default key lookup, so a key
    # at any other path is invisible to this declaration. The declaration
    # therefore has to be right on both machines rather than right per call.
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
    # deploy-side equivalent — which is why an already-installed host's path is
    # populated by a one-off enrollment step instead (the script that did it is
    # in git history; the live host is already enrolled).
    #
    # The attribute name must equal services.tailscale.authKeyFile in
    # hosts/netcup/tailnet.nix. It is a STRING, never a Nix path literal: a path
    # literal copies its contents into the world-readable Nix store. The value
    # never enters the store — proven by construction, since a path literal would
    # be visible in `nix path-info` of the built system.
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

    # THE OPERATOR'S USER-LEVEL ENVIRONMENT, as a SECOND role on the SAME
    # Machine (design D1). It reuses this block's `target.host` and
    # `target.sshOpts` — there is no second Machine declaration and no second
    # SSH identity — and devenv's activation driver drops root to `home.username`
    # at activation time. The system role above activates FIRST, so a system
    # failure is never masked by a user-environment failure.
    #
    # The home-manager backing input is declared in devenv.yaml; this role
    # content lives beside its justification in ./hosts/netcup/operator.nix
    # (the ./tailnet.nix / ./self-deploy.nix pattern, design D3).
    home-manager = import ./hosts/netcup/operator.nix;
  };
}
