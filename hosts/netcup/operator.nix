# hosts/netcup/operator.nix — the operator account's USER-LEVEL environment on
# the host, carried as `machines.netcup.home-manager` (design D1/D3).
#
# WHY A HOME-MANAGER ROLE, NOT MORE `environment.systemPackages`: `hbohlen`
# needs tools and a writable home, not a system service. A system package would
# put `devenv`/`gh` on EVERY account's PATH and would still not create
# `~/projects`; a home-manager role scopes all of it to `hbohlen` and survives a
# re-image through the same loop that deploys the system role. The Machine's
# activation driver drops from root to `home.username` via `runuser` (falling
# back to `sudo -H -u`) and sets `HOME` to `home.homeDirectory`, so the existing
# `root@…` target and `target.sshOpts` in devenv.nix are untouched.
#
# THE HAZARD, STATED WHERE THE ROLE IS: home-manager has NO rollback. If this
# activation fails after the system role has succeeded, the new system
# generation stays active — `machines rollback` does not revert these files
# (design R1, and the MODIFIED `netcup-self-deploy` rollback requirement). That
# is why this first role is deliberately tiny: one pinned package, `gh`, and one
# `mkdir`.
{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  # THE DEVENV PACKAGE, DERIVED FROM THE ALREADY-LOCKED `devenv` INPUT — no
  # third version pin (design D2).
  #
  # This replicates devenv 2.4.0's own internal `devenvPackageFor`
  # (src/modules/machines.nix) rather than adding a pin or reaching for
  # `pkgs.devenv`. The reasons, in order of weight:
  #
  #   * `pkgs.devenv` from this Machine's nixpkgs measures 2.3.1 and has NO
  #     `machines` subcommand — bare `devenv` would then disagree with
  #     `bin/devenv`, which is the exact trap the workstation lives with.
  #   * A `devenv-cli` input pinned to v2.4.0 would be a THIRD pin beside
  #     bin/devenv's tag and this module input — the drift devenv.yaml's own
  #     comments warn about.
  #   * The `devenv:` input is already locked to v2.4.0 (`b904dcb…`), the same
  #     revision the machine's modules come from, so CLI and modules cannot
  #     drift apart.
  #
  # The input is the lightweight `?dir=src/modules` flake, whose `sourceInfo`
  # points at the repository ROOT; when it does not expose `packages` directly,
  # the root flake is loaded by its locked NAR hash. `sourceInfo`/`narHash` are
  # an internal contract, not a public API (risk R4) — a check task asserts
  # `devenv --version` equals `bin/devenv --version`, so a broken contract fails
  # eval loudly instead of silently shipping 2.3.1.
  devenvPackage =
    let
      devenvInput =
        inputs.devenv
        or (throw "The devenv input is required for the operator's devenv package");
      fullDevenvInput =
        if devenvInput ? packages then
          devenvInput
        else if devenvInput ? sourceInfo && devenvInput.sourceInfo ? outPath then
          let
            sourceInfo =
              if devenvInput.sourceInfo ? narHash then
                devenvInput.sourceInfo
              else
                builtins.fetchTree {
                  type = "path";
                  path = devenvInput.sourceInfo.outPath;
                };
          in
          builtins.getFlake (
            builtins.unsafeDiscardStringContext "path:${sourceInfo.outPath}?narHash=${sourceInfo.narHash}"
          )
        else
          throw "The devenv input does not expose packages or locked source metadata";
    in
    fullDevenvInput.packages.${system}.devenv
    or (throw "The devenv input does not provide a devenv package for ${system}");
in
{
  # The account this role configures. These MUST agree with
  # users.users.hbohlen in ./default.nix and with the deploy driver's drop
  # target: the driver compares against `home.username` and hard-errors if the
  # current user matches neither `runuser` nor `sudo` (risk R6).
  home.username = "hbohlen";
  home.homeDirectory = "/home/hbohlen";

  # Symmetric with `system.stateVersion = "26.11"` in ./default.nix. The
  # option is an enum in home-manager, and `"26.11"` is a valid member
  # (design D8) — an older value would only keep pre-26.11 defaults for no
  # reason on a fresh home.
  home.stateVersion = "26.11";

  # `devenv` (pinned 2.4.0, from the locked input above) and `gh`. Nothing
  # else yet: every package here is activation surface with no rollback, and
  # the first role stays minimal on purpose (design R1).
  home.packages = [
    devenvPackage
    pkgs.gh
  ];

  # `~/projects` AS A REAL DIRECTORY, CREATED BY ACTIVATION — never a
  # home-manager file entry, which would make it a symlink into the read-only
  # Nix store and unusable as a working tree (design D9).
  #
  # `entryAfter [ "writeBoundary" ]` runs it with the rest of the file-writing
  # phase. `mkdir -p` is idempotent, so a directory the operator already created
  # by hand survives activation untouched (risk R7), and no collision is
  # possible because no file entry claims the path.
  home.activation.createProjectsDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/projects"
    '';
}
