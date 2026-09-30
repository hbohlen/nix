# hermes/modules/hermes.nix — the workstation home-manager module for hermes.
#
# This is a HOME-MANAGER MODULE, not a devenv module. It lands inside
# `machines.workstation.home-manager` (see ../devenv.nix), and its option
# names are upstream's: R-01 (docs/research/2026-09-29-hermes-nix-module.md)
# verified them against the pinned source of the same flake rev this project
# locks in devenv.lock.
#
# Shape notes:
#   * `imports = [ inputs.hermes-agent.homeManagerModules.default ]` pulls in
#     the upstream option tree (`services.hermes-agent.*`,
#     `programs.hermes-agent.*`). The `inputs` here are home-manager's
#     `extraSpecialArgs`, which devenv fills with the PROJECT's input set
#     (devenv src/modules/machines.nix:207, quoted in R-03 §1.1:
#     `extraSpecialArgs = { inherit inputs self; }`) — so
#     `inputs.hermes-agent` resolves to this sub-project's locked node.
#   * NOT `stateDir` (NixOS-only) — HM takes `hermesHome`, set directly
#     (R-01 §2.3). NOT `installPackage` (removed upstream; setting it trips an
#     assertion) — the install surface is `programs.hermes-agent.enable`.
#   * Linger is a one-time operator prerequisite on Arch
#     (`loginctl enable-linger hbohlen`); Home Manager cannot set it (H14).
{ config, lib, pkgs, inputs, ... }:

let
  hermesHome = "/home/hbohlen/nix/hermes/.hermes";
in
{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  # ── Home Manager identity ───────────────────────────────────────────────
  home.username = "hbohlen";
  home.homeDirectory = "/home/hbohlen";
  # First generation on this host (no prior standalone HM activation was
  # found under ~/.config/home-manager). Matches the machine layer's
  # hosts/netcup/default.nix.
  home.stateVersion = "26.11";

  # ── The installation: `hermes` on PATH + HERMES_HOME in the session ────
  programs.hermes-agent.enable = true;

  services.hermes-agent = {
    enable = true;

    # `op` ON THE UNIT'S PATH, for the 1Password secret source in settings.nix
    # 2.37. The service PATH is `unitPath` only (nix/homeManagerModules.nix:138)
    # and holds the hermes package, bash, coreutils, git, and `extraPackages`
    # (moduleCommon.nix `processPath`). `find_op` falls back to
    # `shutil.which("op")` only when `secrets.onepassword.binary_path` is unset,
    # and the live config's `/usr/bin/op` does not exist on netcup, so the
    # binary is declared here instead of named by path.
    extraPackages = [ pkgs._1password-cli ];

    # H4 — the repo contains the runtime home. No ~/.hermes symlink.
    inherit hermesHome;

    # H7 — native mode; the upstream unit hardens itself
    # (NoNewPrivileges, PrivateTmp, UMask 0077 — homeManagerModules.nix).
    gateway.enable = true;

    # H13 — OAuth tokens live in HERMES_HOME/auth.json, written by the
    # cutover's re-authorization (T-08), not by Nix. authFile stays null:
    # there is no bootstrapping file to install, and the default
    # first-write-wins semantics mean an existing auth.json survives every
    # activation untouched.
    authFile = null;

    # The .env lives OUTSIDE /nix/store (secrets never land in the store —
    # moduleCommon.nix says this about environmentFiles' type verbatim).
    # T-07 renders it imperatively from secretspec-resolved values; this
    # points at the rendered file. `lib.optionals pathExists` keeps
    # evaluation green before the first render: the upstream cats each
    # environmentFiles entry into $HERMES_HOME/.env at activation, and a
    # missing path would fail the whole generation instead of starting
    # keyless.
    environmentFiles = lib.optionals (builtins.pathExists "${hermesHome}/.env") [
      "${hermesHome}/.env"
    ];

    # R-02 §4 — all 45 top-level keys of the live config.yaml, translated
    # 1:1. terminal.cwd deliberately omitted (R-02 §5); see settings.nix.
    settings = import ./settings.nix;

    # H11 — identity/memory declared by Nix. hermesHomeFiles installs into
    # HERMES_HOME (NOT `documents`, which installs into workingDirectory).
    # Tracked as real files under hermes/docs/ — the copy becomes live at
    # activation and edits belong in the repo from then on.
    hermesHomeFiles = {
      "SOUL.md" = ../docs/SOUL.md;
      "memories/USER.md" = ../docs/USER.md;
    };
  };
}
