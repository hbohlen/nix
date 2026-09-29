# modules/tooling.nix — the non-agent tools the shell layer owns.
#
# Row source: the Placement table in `.scratch/devenv-layering/map.md`
# (decisions D18-D32). Every entry here is a `Shell` row: declared in this
# module, active on `cd`, dead when the shell exits.
#
# D7 makes this declaration AUTHORITATIVE inside the project even where pacman
# carries the same binary. The workstation PATH puts `~/.local/bin` and the
# devenv profile ahead of /usr/bin, so `which gh` inside the shell resolves to
# the store path below, not to /usr/bin/gh.
#
# D25 splits the source: NON-agent tooling comes from the LOCKED nixpkgs
# (`pkgs`), agent CLIs come from the pinned `llm-agents` input
# (`modules/agents.nix`). D30 is the per-tool exception: `openspec` is this
# repo's workflow tool and comes from nixpkgs so its version matches the change
# schema.
{ pkgs, lib, ... }:

{
  packages = with pkgs; [
    # ---- pacman rows that become shell rows (D7, D12) ----------------------
    gh
    git
    jujutsu # `jj`
    # `op`. UNFREE — `allow_unfree: true` in devenv.yaml is what lets this
    # evaluate, and that file records why it is declared rather than left to an
    # ambient NIXPKGS_ALLOW_UNFREE.
    _1password-cli

    # ---- nix profile rows that become shell rows (D12) --------------------
    nixd
    carapace # completion engine; wires into nu, see modules/shell.nix

    # ---- mise / npm rows D14 keeps ---------------------------------------
    uv # the one mise-managed tool the table keeps as Shell
    wrangler # the npm shim named `cloudflare`; nixpkgs carries it as wrangler

    # ---- the repo's own workflow tool (D30) ------------------------------
    openspec

    # ---- credential helpers (D18 rule 2) ---------------------------------
    # `git-credential-secretspec` and `docker-credential-secretspec` earn a row
    # because declared `git` needs the former to reach the 1Password vault.
    # They ship WITH the `secretspec` prerequisite (D3, installed outside the
    # shell), so there is no package to add here. Recorded so the row has a
    # reason rather than an omission.
  ];
}