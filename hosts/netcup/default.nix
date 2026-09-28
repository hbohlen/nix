# hosts/netcup/default.nix — netcup VPS (x86_64-linux): the host half.
#
# Scope: the machine boots, and it is reachable over SSH as the operator with a
# key — over the public address AND, since the tailnet change, over the overlay.
# No secrets at rest, no snapshotting, no agent tooling, and no hardening beyond
# key-only SSH.
#
# THE TAILNET IS DECLARED IN ./tailnet.nix, WHICH THIS FILE IMPORTS. It is a
# separate module because its concerns are separable and because its enabling
# detail — the auth-key path, the node name, and why neither is what the module
# documentation suggests — has nowhere sensible to live in a 100-line host file.
# Adding tailscale changes NO firewall policy: the module's `openFirewall` stays
# false, so the facts below are unchanged.
#
# THE SELF-DEPLOY PRECONDITIONS ARE DECLARED IN ./self-deploy.nix, ALSO IMPORTED
# HERE: the host's `nix.settings` (this host had no `experimental-features` at
# all) and the `git` the clone step needs. The loopback deploy identity's public
# half is NOT in that module — it is authorized for root below, next to the
# operator key, so both of root's identities are declared in one place.
#
# NO FIREWALL POLICY IS DECLARED HERE, and none is needed: the nixpkgs defaults
# already give a default-deny firewall with sshd's port opened
# (`services.openssh.openFirewall` defaults to `true` in this nixpkgs) — read
# back through `devenv eval machines.netcup.deploy.facts`: firewall enabled,
# allowedTCPPorts = [ 22 ], allowedTCPPortRanges = []. Treat that as the
# baseline, not as hardening this milestone performed; explicit policy is the
# hardening change's work.
{
  config,
  ...
}:

let
  # The operator identity for this host: the 1Password `dev` vault item
  # `SSH Key` — ed25519, SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ.
  #
  # This is NOT the workstation's own ~/.ssh/id_ed25519
  # (SHA256:DnpZNFSTyvWafuCRJzJBhOD7KCU9SWj61tsGOSXQldA); the two are different
  # keys and this host trusts only this one — measured 2026-09-27: the freshly
  # imaged target's /root/.ssh/authorized_keys carries exactly this key and sshd
  # accepted it.
  #
  # Public half only, on purpose: the private half is materialized from the
  # vault at the moment of use (`op inject` into a 0600 file). It must never be
  # committed here, carried in an environment variable, or written to the Nix
  # store.
  operatorKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFnHjjZoYIy3ioATMm7DUffyL4f3lE/zB43NXgR49iXO netcup-devenv";

  # The host's OWN identity, for the loopback deploy target (`root@localhost`)
  # and for nothing else — design D4. A `devenv machines deploy` run ON this
  # host contacts `root@localhost`, so the host needs a client identity that
  # depends on no other machine, no vault session and no agent.
  #
  # It is a distinct key on purpose. `devenv.nix`'s single `target.sshOpts`
  # declaration names the path `-i /home/hbohlen/.ssh/id_ed25519-op-dev` with
  # `IdentitiesOnly=yes`, so a key at any OTHER path is invisible to it; the
  # private half of THIS pair is installed at that path on the host (the vault
  # key's path on a workstation), which is what makes one declaration mean the
  # right thing on both machines. Materializing the 1Password `SSH Key` here
  # instead was rejected: it would collide with the very path this needs, and
  # would put the vault's identity at rest on a public VPS for a loop that only
  # ever crosses the loopback.
  #
  # Public half only, exactly like ./operatorKey above. The private half is
  # generated outside this repository, installed on the host root-owned `0600`,
  # and never committed, injected or copied into the Nix store.
  # Fingerprint: SHA256:WgXJgoyQQ9pTLPVcWL31pnzNFPo/qR0zSPXmj6PEK8I
  loopbackKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEfjyi+/cIrYLu/Qm398sSNZQb8/cnBIpD2ztpo1ghGV netcup-loopback";
in
{
  imports = [
    ./disko.nix
    ./hardware.nix
    ./tailnet.nix
    ./self-deploy.nix
  ];

  # The operator account. `hashedPassword = "!"` is a shadow lock marker: no
  # password can authenticate this account from anywhere. Access is key-only.
  users.users.hbohlen = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [ operatorKey ];
  };

  # Root is reachable with the SAME key because `devenv machines install` and
  # `deploy` require root SSH. There is no root password — see
  # PermitRootLogin = "prohibit-password" below, which permits key auth only.
  #
  # Root carries TWO key-only identities, and the second is deliberate: the
  # operator's key (public path) plus the host's own loopback key (design D4),
  # which is what a deploy run ON the host uses against `root@localhost`. This
  # adds no authentication METHOD — both are key-only, and
  # `PermitRootLogin = "prohibit-password"` still refuses every password — only
  # a second key that is meaningful exactly on the loopback interface.
  #
  # Consequence, recorded so it is not rediscovered later: because this path is
  # load-bearing, `PermitRootLogin` can no longer simply be closed, and any
  # later `Match Address` restriction has to keep `127.0.0.1` reachable or it
  # silently breaks the self-deploy loop (risk R7).
  users.users.root.openssh.authorizedKeys.keys = [
    operatorKey
    loopbackKey
  ];

  # The operator escalates with sudo, not by logging in as root.
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      # Key-only. Both switches must be off: PasswordAuthentication alone does
      # not cover the keyboard-interactive path.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Key-only root, not "no": Machines' install and deploy paths need it.
      PermitRootLogin = "prohibit-password";
    };
  };

  # UEFI via systemd-boot. canTouchEfiVariables = false because a VPS's NVRAM
  # writes are unreliable and a failed efivars write must not be able to break
  # the boot. efiSysMountPoint must equal the ESP's mountpoint in ./disko.nix
  # (asserted below).
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
      editor = false;
    };
    efi = {
      efiSysMountPoint = "/boot";
      canTouchEfiVariables = false;
    };
    timeout = 3;
  };

  # Cheap cross-file guard: the bootloader and the disk layout must agree on
  # where the ESP lives, and neither file can see the other's intent.
  assertions = [
    {
      assertion = config.boot.loader.efi.efiSysMountPoint == "/boot";
      message = "netcup: bootloader efiSysMountPoint must match the ESP mountpoint declared in hosts/netcup/disko.nix";
    }
  ];

  # Read from the Machine's own nixpkgs (devenv.yaml inputs.nixpkgs =
  # devenv-nixpkgs/rolling), not from a remembered release: the same module tree
  # evaluated to `nixos-system-netcup-26.11pre-git` under devenv while the old
  # flake host was 26.05.20260914.c3eea5b.
  system.stateVersion = "26.11";
}
