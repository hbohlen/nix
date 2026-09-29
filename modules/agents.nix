# modules/agents.nix — the agent CLIs, from the pinned `llm-agents` input.
#
# D19/D25: one input, declared once, serving BOTH the shell layer on the
# workstation and netcup's machine layer (`hosts/netcup/agents.nix`). The host
# already consumes this input for `hermes-agent` and `herdr`, so this module is
# the workstation half of the same declaration.
#
# THE COST, STATED WHERE IT IS PAID: `llm-agents` deliberately does NOT follow
# nixpkgs (design D2 in devenv.yaml), so this brings a SECOND nixpkgs into the
# shell's closure graph. That is design R1/R2. On the workstation the price is a
# larger download and a second evaluation; the numtide cache the host declares
# is what keeps the host side a download rather than a build.
#
# D20 is why these are ADDITIONS and not replacements: the native install of
# each self-updating CLI stays on disk, so a broken shell does not take the
# agent away. The shell copy is what `cd` into this project makes authoritative.
#
# D30 is why `openspec` is NOT here: it is the repo's workflow tool and comes
# from nixpkgs in modules/tooling.nix.
{ pkgs, lib, inputs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  llm = inputs.llm-agents.packages.${system};
in

{
  packages = [
    llm.hermes-agent # `hermes`; also a netcup host row (D28)
    llm.herdr # `herdr`; the pane tool, and the multiplexer of choice (D23)
    llm.claude-code # `claude`
    llm.codex # `codex`; the mise npm copy dies with mise (D14)
    llm.opencode2 # `opencode2` 2.0.18 — the 2.x line, measured as what runs
    llm.agent-browser # named by the user (D27)
    llm.parallel-cli # named by the user (D27)
    llm.luvus # named by the user, wired to nothing yet (D27)
  ];
}