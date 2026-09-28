# hosts/netcup/agents.nix — the agent tooling the operator account carries:
# `hermes` and `herdr`, installed on `hbohlen`'s PATH as part of the existing
# home-manager role (design D1/D6). This change installs them; it does not start
# them. No service, no timer, no boot-surviving user unit, no provider
# credential (design D5).
#
# WHY A SEPARATE MODULE: the same reason ./tailnet.nix and ./self-deploy.nix
# are separate. The two packages are small; the justification for where they
# come from is not, and it does not belong in `operator.nix`, which is about
# devenv, gh and `~/projects` (the "small config, large justification" pattern
# this repository uses everywhere).
#
# WHY THE PACKAGES COME FROM `inputs.llm-agents`, NOT FROM `pkgs` (design D2).
# Neither `hermes-agent` nor `herdr` exists in this Machine's nixpkgs, and both
# are absent from `cache.nixos.org` and `devenv.cachix.org`. They are published
# by `numtide/llm-agents.nix`, which this repository now pins as an input that
# deliberately does NOT follow nixpkgs: llm-agents builds against its own
# `nixpkgs-unstable`, and following ours would trade the prebuilt binaries for
# a from-source npm + Rust/PyO3 + zig build. Reaching for `pkgs.hermes-agent`
# here would fail eval with `attribute 'hermes-agent' missing`; reaching for
# `nix run github:…` would put nothing on PATH and would not survive a re-image.
#
# THE GUARD PATTERN IS COPIED FROM operator.nix's `devenvPackage`. If the
# `llm-agents` input is removed from devenv.yaml, eval fails with a message
# naming the missing input instead of a bare `attribute 'llm-agents' missing`.
{
  pkgs,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  llmAgents =
    inputs.llm-agents
    or (throw "The llm-agents input is required for the operator's agent tooling (hermes-agent, herdr)");

  # `or` catches a missing attribute anywhere in the path, so this fails with a
  # targeted message whether the input lost its `packages` set, its `<system>`
  # attribute, or just this package.
  agentPackage =
    name:
    llmAgents.packages.${system}.${name}
    or (throw "The llm-agents input does not provide ${name} for ${system}");
in
{
  # `hermes-agent` installs `hermes` and `herdr` installs `herdr`. Listed
  # explicitly rather than via `builtins.attrValues` so a future llm-agents
  # package does not silently join the operator's PATH.
  home.packages = [
    (agentPackage "hermes-agent")
    (agentPackage "herdr")
  ];
}
