# Proposal: add-netcup-agent-tooling

## Why

The operator account on netcup is now a declared home-manager role
(`add-netcup-operator-env`) carrying `devenv` and `gh` — but it carries no agent
tooling. Two tools this workstation's own workflow already assumes are absent
there: **`hermes-agent`**, the self-improving agent whose `SKILL.md` format the
repository's `.agents/skills` are written for (and whose project skills the
workstation links as `.hermes/skills`), and **`herdr`**, the terminal workspace
manager the handoff's pane-control workflow names (`docs/handoff-followups.md`
§7; `bb-cli` + `devops/herdr-pane-control`). An agent session on netcup
therefore has neither an agent nor a workspace manager, and there is no declared
way to put them there.

Both are packaged by `numtide/llm-agents.nix` (measured 2026-09-28:
`nix flake metadata github:numtide/llm-agents.nix` → rev `e28ea84`), which is
**not an input of this repository**, and neither package is present in the two
caches the host currently declares (`cache.nixos.org`, `devenv.cachix.org`). The
change that adds them must also answer where the host fetches them from — the
same question `add-netcup-operator-env` answered for `devenv.cachix.org`.

**Milestone:** the third milestone's operator-tooling thread (the host runs its
declared NixOS with a tailnet, a self-deploy loop, and an operator environment).
It advances that thread by exactly one moving part: two user-level agent tools on
the operator's `PATH`, resolved from a pinned flake input.

## What Changes

- **A new `llm-agents` input** in `devenv.yaml`, hand-added (comments preserved —
  `devenv inputs add` drops them), **not following `nixpkgs`**. `llm-agents.nix`
  is only built and tested against its own pinned `nixpkgs-unstable`, and its
  README states that following nixpkgs costs the binary-cache hits this change
  depends on; the input therefore brings a second nixpkgs evaluation, recorded
  below as a deliberate exception.
- **`hermes-agent` and `herdr` on `hbohlen`'s `PATH`**, sourced from
  `inputs.llm-agents.packages.${system}.{hermes-agent,herdr}` in the home-manager
  role — not from `pkgs`, which does not carry them. The role stays a
  home-manager role on the same Machine; no second declaration, no second
  identity.
- **`https://cache.numtide.com` declared in the host's `nix.settings`**
  (substituters + `trusted-public-keys`, `lib.mkAfter` so the existing caches
  survive), beside the existing `devenv.cachix.org` declaration, because both
  packages are absent from `cache.nixos.org` and would otherwise be compiled from
  source on the build machine — which, for a host-side self-deploy, is the host
  itself.
- **Spec deltas**: a new `netcup-agent-tooling` capability (the tools, the pinned
  input, the second-nixpkgs exception) and an **ADDED** requirement on
  `netcup-self-deploy` (the host declares the substituter its agent tooling is
  fetched from — ADDED rather than MODIFIED so it does not collide with the
  adjacent requirement `add-netcup-operator-env` is already modifying).

Non-goals, stated explicitly:

- **Not the agent-runner service model.** This change installs tools on `PATH`; it
  declares no service, no timer and no `users.users.<name>.linger`. An always-on
  agent job remains `decide-agent-runner-service-model`'s decision (handoff
  ledger #10), which explicitly deferred a concrete runner until one exists.
- **No provider credentials or model configuration.** `hermes` is not useful
  without a model provider; the `dev` vault holds `HERMES_API_SERVER_KEY`, but it
  is **not** added to `secretspec.toml` here. Declaring it is a separate change
  once the consumer is defined (its field and reason are not yet known).
- **No `herdr` integration wiring and no `hermes` skills/config wiring.** `herdr`
  ships per-agent hook sources at `$out/share/herdr/integrations` for declarative
  wiring; this change only puts the binary on `PATH`. Linking the repository's
  `.agents/skills` into the host's `~/.hermes/skills` is likewise out of scope.
- **No `follows: nixpkgs`** and no `overlays.shared-nixpkgs` (a Machine may not
  set `nixpkgs.overlays` — the same externally-created-instance failure the
  repository already records for `nixpkgs.config`).
- **The workstation stays unmanaged.** The repository cannot declare the
  workstation's `nix.conf`; the one-time operator action it needs is documented,
  not encoded (same shape as materializing the vault identity).
- **No devshell packages.** The `devenv shell` half of `devenv.nix` stays empty
  by design; these tools land on the host's operator account, not the
  workstation's project shell.
- **No hardening, no second host, no `trusted-users` widening.**

## Capabilities

### New Capabilities

- `netcup-agent-tooling`: the agent tooling the operator account carries — which
  packages (`hermes-agent`, `herdr`), where they come from (a pinned
  `llm-agents` flake input, never `pkgs`), and the deliberate
  second-nixpkgs-in-the-graph exception that comes from not following nixpkgs.
  It is scoped to tooling on `PATH`; it declares no running process and no
  credential.

### Modified Capabilities

- `netcup-self-deploy`: the host's declared `nix.settings` gain a **second**
  substituter and public key (`cache.numtide.com`), so the agent tooling's
  packages substitute on the host instead of compiling there. This is an
  **ADDED** requirement, not a MODIFIED one: the adjacent requirement ("The host
  satisfies the nix preconditions a build and deploy need") is already being
  modified by the in-flight `add-netcup-operator-env`, and editing the same block
  from two branches is a merge collision this change can avoid.

## Impact

- **Files**: `devenv.yaml` (hand-added `llm-agents` input), a new
  `hosts/netcup/agents.nix` (the two packages, imported by the home-manager
  role), `hosts/netcup/operator.nix` (the `imports` entry),
  `hosts/netcup/self-deploy.nix` (the second cache declaration),
  `docs/handoff-followups.md` (ledger closure at archive).
- **Host**: one deploy. System role applies the `nix.settings` change first;
  home-manager then symlinks two new packages into `hbohlen`'s profile. No
  service starts, no port opens, no firewall fact changes, no re-image.
- **Both machines**: the build is heavier on whichever machine runs it. The
  deploy builds on the controller; a self-deploy loop builds on the host. The
  declared substituter is what keeps that a download rather than a Rust/npm/zig
  build on either side.
- **Vault**: unchanged. No secret is declared or read.
- **Reference honesty**: relative to `~/projects/nixos` — nothing is inherited.
  A per-project devenv shell carrying agent tools is not the shape here; the
  tools belong to the operator's declared account, which the reference does not
  have.
