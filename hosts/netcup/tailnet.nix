# hosts/netcup/tailnet.nix — netcup's membership in the tailnet, as a declaration.
#
# WHAT THIS FILE IS FOR: making enrollment a property of the MACHINE. The auth
# key is delivered to a host path by `install.secrets` (devenv.nix), and this
# module tells the pinned tailscale module to read that path — which generates
# `tailscaled-autoconnect.service`, a unit that polls `BackendState` and sends
# the key only while the node is NOT Running.
#
# It matters because the hardening change that follows closes public SSH, and a
# configuration that closes public SSH is only survivable if the overlay comes up
# unattended on the first boot after an install. On the already-installed host
# this module's path is populated by a one-off enrollment step instead — that
# script is in git history, and the live host is already enrolled —
# because `deploy` does NOT refresh bootstrap files (measured: the Machine option
# tree has install.{kexec,extraFiles,secretspec,secrets,encryptionKeys,copyHostKeys}
# and no deploy-side equivalent; the docs say it outright).
#
# WHY THE PATH IS A PLAIN STRING: `services.tailscale.authKeyFile` is
# `types.path`, which a string beginning with "/" satisfies — verified against
# the pinned nixpkgs, where `lib.types.path.check "/var/lib/tailscale/authkey"`
# is true and `check "var/lib/..."` is false. A Nix path literal would be copied
# into the world-readable Nix store, so it must stay a string. The same string is
# the attribute name of the `install.secrets` entry in devenv.nix — one value in
# two files, which have to be changed together.
#
# WHY /var/lib AND NOT /run: the module's own documented example is
# "/run/secrets/tailscale_key", which is wrong for this use. `install.secrets`
# writes files after nixos-install and before reboot, so a tmpfs path would be
# empty at the very first boot that needs it. /var/lib/tailscale is the daemon's
# own state directory: root-only, persistent, and not managed by NixOS.
{
  ...
}:
{
  services.tailscale = {
    enable = true;

    # Read by tailscaled-autoconnect.service. Never in the store; see the header.
    authKeyFile = "/var/lib/tailscale/authkey";

    # THE NODE NAME IS PINNED HERE, INDEPENDENTLY OF networking.hostName, which
    # stays "netcup". MagicDNS derives the name from the node name, and the node
    # name comes from the OS hostname unless `--hostname` overrides it.
    # Setting networking.hostName = "nc" instead would silently re-scope the
    # host's prompt, journal identifier, DHCP identity and the
    # `nixos-system-netcup-*` derivation name — for a cosmetic name.
    #
    # `extraUpFlags` applies to the `tailscale up` call only, i.e. at enrollment.
    #
    # The TAG is deliberately NOT set here: it comes from the auth key minted in
    # the admin console (tag:server), so it exists only in the tailnet. It cannot
    # be read out of this closure; the only place it becomes visible is
    # `tailscale status --json` after enrollment.
    extraUpFlags = [ "--hostname=nc" ];

    # `openFirewall` stays at its default `false`, so this change adds NO port.
    # The machine's "only the SSH port is exposed" property survives: the tailnet
    # is reached over port 22, which is already open to everything. Confining
    # sshd to the overlay is the HARDENING change's work and will need deliberate
    # policy — this module declares none, on purpose.
  };

  # WHY THE ENROLLMENT UNIT IS SKIPPED WHEN THE KEY IS ABSENT. Measured
  # 2026-09-27, on the first attempt to deploy this file at all:
  # `switch-to-configuration switch` treats a FAILED new unit as a hard error.
  # The generated `tailscaled-autoconnect.service` fails whenever the key is not
  # yet at `authKeyFile` — it loops, hits
  # `cat: /var/lib/tailscale/authkey: No such file or directory`, and is killed
  # by its 90 s start timeout. The activation then printed
  # `warning: the following units failed: tailscaled-autoconnect.service`,
  # exited 4, and devenv rolled the entire transaction back
  # (`phase: "rolled-back"`, `previousSystem` restored). That absent-key state is
  # exactly the pre-enrollment state this change passes through on purpose, so
  # without a condition the deploy can never be accepted and the tailnet can
  # never be reached — the failure mode is not "the unit is untidy", it is "the
  # change cannot be deployed at all".
  #
  # ConditionPathExists turns the absent-key case into a SKIP rather than a
  # failure. Measured on this host with a probe unit, 2026-09-27: a
  # condition-skipped unit reports `systemctl start` rc=0, `is-failed: inactive`,
  # `Result=success`, `ConditionResult=no` — so switch-to-configuration does not
  # count it among the failed units and the switch proceeds.
  #
  # The unit still runs in every state that needs it: at the first boot after an
  # install (`install.secrets` writes the key before the reboot), and whenever
  # an operator starts it once the key is in place.
  #
  # `unitConfig` merges into the unit's [Unit] section, so this does not replace
  # anything the pinned tailscale module generated — the preflight greps the
  # built unit for BOTH this condition and the module's own ExecStart script.
  systemd.services."tailscaled-autoconnect".unitConfig.ConditionPathExists =
    "/var/lib/tailscale/authkey";
}
