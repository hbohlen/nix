# devenv.nix — the netcup HOST, declared as a devenv Machine (devenv 2.4+).
#
# One file, two consumers: `devenv shell` for the workstation half and
# `devenv machines install|deploy` for the host half. The workstation half lives
# in ./modules/*.nix and is imported below, per D13.
#
# Use `bin/devenv` (pinned 2.4.0), NEVER bare `devenv` — on a workstation.
# The global profile binary there is 2.2.2 and has no `machines` subcommand.
# Since ticket 08 there is no home-manager role on the host either, so the
# host's CLI is this same `bin/devenv` script plus its `.devenv-toolchain`
# (built with `nix build`, see bin/devenv's header): one entry point, both
# machines.
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
    ./modules/ingress.nix # prototype ingress: Caddy + DNS-01 (D11, D15)
    ./modules/dsh.nix # the declared dsh web instance the ingress fronts
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

    # THE DEPLOY KNOBS, declared rather than left to the module defaults because
    # the research's irreducible layer names them (`devenv-machines-minimal-layer.md`,
    # items 4). They are the only two deploy-time controls the machine keeps.
    #
    # rollbackTimeout is the documented default, stated so the number is a
    # decision here rather than an upstream default nobody read. The bound is
    # 30..600 s; the promoted shell stack's activation copies closures, so there
    # is no reason to shorten it.
    deploy.rollbackTimeout = 300;

    # healthCheck is deliberately the module default ("true"): the real gate is
    # transactional activation plus the target-side watchdog, and a stricter
    # check written now would assert a state (Caddy and the upstreams answering)
    # that the promotion has not landed yet — a health check that fails on a
    # healthy host is how a green deploy gets rolled back. The promoted stack's
    # real check is ticket 08's deploy step.
    deploy.healthCheck = "true";

    nixos =
      { ... }:
      {
        imports = [ ./hosts/netcup/default.nix ];

        # Set here, not in the host file: the hostname is the declaration's
        # business in this layout, the same way devenv owns hostPlatform.
        networking.hostName = "netcup";
      };

    # THE home-manager ROLE IS GONE (ticket 08, D48). It carried exactly
    # `devenv`, `gh`, `hermes-agent` and `herdr` for the `hbohlen` account, plus
    # `~/projects`. Each of those is now shell-layer or prerequisite work:
    #
    #   * `gh`, `hermes-agent` and `herdr` are declared in ./modules/ (tooling,
    #     agents) and arrive when the shell is entered — the D9/D20 rule that
    #     the shell is authoritative inside the project.
    #   * `devenv` itself is the shell runner's prerequisite, and on the host it
    #     is this repo's `bin/devenv` + `.devenv-toolchain` built with `nix`,
    #     not a package a role installs (bin/devenv's header).
    #   * `~/projects` was an operator convenience, not a machine property.
    #
    # Removing the role also removes the input it needed (devenv.yaml) and the
    # no-rollback hazard hosts/netcup/operator.nix documented: with the role
    # gone, a failed activation cannot leave a half-written user environment
    # behind. The Machine keeps the irreducible six — target.host, the nixos
    # role, disko, install.*, deploy.healthCheck, deploy.rollbackTimeout — and
    # nothing else.
  };

  # THE HOST FACTS THE SHELL MODULES PARAMETERIZE (ticket 08 step 2, D50).
  #
  # The same shell modules run on both machines, but the ingress differs: contabo
  # coexists with its system caddy.service on the high ports (D21) and does NOT
  # declare the port-less dsh route (its system Caddy owns it, D42); netcup has
  # no other Caddy, so it owns port-less 443 and must carry the `@dshEntry` +
  # `@dsh` route from docs/dsh-web-endpoint.md, or phone entry breaks.
  #
  # devenv selects a profile by the RUNNING hostname
  # (`profiles.hostname.<uname -n>.module`), so `devenv up` on either machine
  # renders the right Caddyfile and the right dsh `--trusted-host` list with no
  # flag and no untracked local file to keep in sync. D13's "no profiles" was
  # about toolset selection; a hostname profile that selects host facts is the
  # mechanism it explicitly left room for ("re-introducing profiles later does
  # not rewrite the file layout"). A host with no profile keeps the modules'
  # false/null defaults and still evaluates — D3's portability property.
  #
  # The addresses are measured facts, not conventions. `tailscale status`
  # reports contabo as 100.115.197.61 and netcup as 100.95.168.15. netcup's
  # MagicDNS name is `nc.worm-hue.ts.net`, not `netcup...`: the node name is
  # pinned to `--hostname=nc` in hosts/netcup/tailnet.nix, independently of
  # `networking.hostName = "netcup"`.
  profiles.hostname.contabo.module.ingress = {
    enable = true;
    tailnetIp = "100.115.197.61";
    tailnetName = "contabo.worm-hue.ts.net";
    # dashboardPort/gatewayPort keep the module's 9443/9444 defaults, and
    # serveDsh stays false: the system Caddy owns the port-less dsh route here.
  };

  profiles.hostname.netcup.module.ingress = {
    enable = true;
    tailnetIp = "100.95.168.15";
    tailnetName = "nc.worm-hue.ts.net";
    # Port-less 443 for both Hermes sites, and the dsh route this host owns.
    dashboardPort = 443;
    gatewayPort = 443;
    serveDsh = true;
  };
}
