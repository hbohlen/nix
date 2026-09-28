# hosts/netcup/self-deploy.nix — the preconditions that let the host rebuild
# itself, DECLARED HERE rather than applied by hand to the running system.
#
# WHY A SEPARATE MODULE: the same reason ./tailnet.nix is one. These two
# settings are small; their justification is not, and none of it belongs in the
# host file (./default.nix), which is about sshd, users and the bootloader.
#
# WHY THEY ARE DECLARED AT ALL (design D6). Measured on the live host
# 2026-09-27, before this change:
#
#   grep experimental-features /etc/nix/nix.conf  ->  experimental-features =
#
# — an EMPTY value, so `devenv` cannot run on the host at all: no `flakes`, no
# `nix-command`. A per-invocation `NIX_CONFIG="experimental-features = …"` was
# sufficient for the read-only probes that preceded this change, and is the
# right tool for testing before it lands. It is not the right tool for the
# steady state, because a setting that lives in an operator's environment is
# missing whenever someone else, or a script, runs the command. Declaring it
# here also makes it survive a rebuild, which is the spec scenario "The settings
# survive a rebuild".
#
# ORDERING (risks R6 and D7): the host cannot run `devenv` until these land, so
# the FIRST application of this change must come from the workstation. A
# host-side attempt before that fails with an error that has nothing to do with
# this change.
{
  pkgs,
  ...
}:

{
  # `nix-command` and `flakes`, and nothing else.
  #
  # `trusted-users` is deliberately NOT set: the pinned nixpkgs' default is
  # `root`, re-measured on the live host as `trusted-users = root`, which is
  # exactly what design D5 wants. Adding the operator account would be a
  # permanent, wider grant, spent on a loopback deploy that runs as root anyway.
  # A non-root copy already fails the trusted-signature check on this host
  # (`require-sigs = true`), which is the failure docs/handoff-followups.md §3
  # records from the non-root deploy attempt.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # git and the 1Password CLI, and nothing else.
  #
  # GIT: measured absent on the host 2026-09-27 (`command -v git` prints
  # nothing; so do `op`, `devenv` and `jq`), and the self-deploy loop needs it to
  # hold a checkout: the clone step puts this repository at /home/hbohlen/nix on
  # the host, and the drift check compares the host's revision against the pushed
  # one. jj is deliberately NOT added — building and deploying need git only.
  #
  # `onepassword` IS REQUIRED BY DESIGN D3, AND IT IS NOT AN EXTRA. `devenv
  # machines` resolves the whole SecretSpec profile on every invocation, and
  # SecretSpec's 1Password provider is a WRAPPER AROUND THE `op` BINARY rather
  # than an API client. Measured 2026-09-27 on the workstation by putting a
  # sentinel `op` first on PATH and watching `machines info` invoke it:
  #
  #   SHIM-SENTINEL: op was invoked with: vault list --format json
  #
  # The pinned secretspec 0.21.0 also carries the literal string "OnePassword CLI
  # (op) is not installed." plus an install hint, "NixOS: nix-env -iA
  # nixpkgs.onepassword", which is this package. Without it the host cannot
  # resolve TS_AUTH_KEY, so no `machines` command runs there at all: the
  # credential at rest D3 places on the host is necessary but NOT sufficient, and
  # this is the other half.
  #
  # `SECRETSPEC_OPCLI_PATH` exists and could point at an `op` carried over from
  # the workstation's store instead. Rejected for the same reason D6 rejects an
  # ambient `NIX_CONFIG`: a variable naming a store path is missing whenever a
  # script or another operator runs the command, and that path would not survive
  # the host's own rebuild.
  #
  # THE ATTRIBUTE NAME IS MEASURED, NOT GUESSED. `pkgs.onepassword` — the name
  # secretspec's own install hint prints — DOES NOT EXIST here, and neither does
  # `pkgs._1password`: the pinned nixpkgs evaluates
  # `error: attribute 'onepassword' missing`, and `pkgs._1password` is a `throw`
  # ("has been renamed to/replaced by '_1password-cli'", converted 2025-10-27).
  # The real attribute is `pkgs._1password-cli`, whose `mainProgram` is `op` and
  # whose version is 2.39.0 — the same version the workstation runs.
  #
  # It is UNFREE (`license = lib.licenses.unfree`), and a Machine module may not
  # set `nixpkgs.config` — devenv builds `pkgs` outside the module system, so
  # doing it here fails eval with "Your system configures nixpkgs with an
  # externally created instance". The policy is declared in devenv.yaml
  # (`allow_unfree: true`) instead, which is where this repository's convention
  # puts it.
  environment.systemPackages = [
    pkgs.git
    pkgs._1password-cli
  ];
}