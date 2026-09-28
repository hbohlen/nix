# Proposal: add-netcup-operator-credentials

## Why

`add-netcup-operator-env` gave `hbohlen` a user environment (pinned `devenv`,
`gh`, `~/projects`, `devenv.cachix.org`), but the credential that makes `gh`
usable was placed where the *loop* needs it, not where a person works: the
1Password service-account token is at `/root/.config/op-sa-token` (design D3 of
that change), and `hbohlen` cannot read it. Measured 2026-09-28 on the host:
bare `gh auth status` as `hbohlen` prints `You are not logged into any GitHub
hosts`, and `secretspec run -- gh auth status` as `hbohlen` fails with
`Permission denied` on root's token — so the authentication the previous change
proved green only works when a command is launched **as root**.

That is backwards for daily work. Every deliberate statement in the handoff and
the previous design says the operator account is where a human or agent works
(`~/projects` exists for it; the agent-runner follow-up — handoff ledger #10 —
is premised on it); root is a formality that the self-deploy loop happens to
require. An operator environment whose credential is reachable only through
root is not the operator environment the last change claimed to deliver.

This change advances the **operator-tooling** follow-up (handoff ledger #9) by
finishing what `add-netcup-operator-env` started: the account that works is the
account that can authenticate.

## What Changes

- **`hbohlen` gets the vault credential**, as its own service-account token
  file, owned by `hbohlen`, mode `0600`. Root keeps its existing copy — the
  self-deploy loop still runs as root and must keep resolving the profile — so
  the change **adds a second holder rather than moving the first**. Delivery is
  activation-seeded (the `loopbackKey` pattern): a root-owned source seeded
  once, copied into `hbohlen`'s home by the role's activation, never through
  the Nix store.
- **A `gh` wrapper on `hbohlen`'s `PATH`** that resolves `GH_TOKEN` through
  `secretspec run` for the single invocation and `exec`s the real `gh` — so
  `gh auth status`, `gh api user` and `gh pr …` work as `hbohlen` with **no
  token at rest**. Measured 2026-09-28: `secretspec run` injects `GH_TOKEN`
  (40 chars, `ghp_`) into the child environment, which is the variable `gh`
  reads natively.
- **A deliberate non-goal, named so it is not rediscovered:** writing
  `~/.config/gh/hosts.yml`. That is the only way `gh` persists a login, it is
  plaintext YAML on a public VPS under the account that runs agents, and it
  contradicts the blast-radius posture both this repo and ADR-0005 reuse
  (resolve per use; no PAT at rest). The wrapper gives the same UX without it;
  the design records the trade-off and the cost of the per-use resolve so a
  future operator can flip knowingly.
- **Spec deltas**: `netcup-operator-env` (MODIFIED: the credential requirement
  is restated as the *operator's* credential, not root's; ADD: the `gh` wrapper
  requirement and the no-`hosts.yml` posture) and `netcup-self-deploy`
  (MODIFIED: the loop's credential requirement keeps root's copy explicit, so
  adding the operator's cannot silently break the loop).

Non-goals, stated explicitly:

- **The vault item is unchanged.** `GH_TOKEN` already exists in `dev` and is
  already declared in `secretspec.toml`; this change moves no secret value and
  creates no item.
- **No `hosts.yml`, no `gh auth login` on the host** — see above.
- **No `nix.conf access-tokens`** (GitHub API rate limits for nix): still an
  unmeasured need with its own delivery problem; out of scope as before.
- **No change to `root`'s token file**, its mode, or the self-deploy path.
- **No agent-runner service model** (handoff ledger #10) and no `sudo`
  wrapper — `hbohlen` holds the credential directly, and passwordless `wheel`
  sudo is already declared, so a sudo indirection would add friction for
  nothing.

## Capabilities

### Modified Capabilities

- `netcup-operator-env`: the vault credential belongs to `hbohlen`, delivered
  as its own `0600` file; `gh` authenticates through a resolving wrapper with
  no token at rest; `~/.config/gh/hosts.yml` is deliberately absent.
- `netcup-self-deploy`: the loop's requirement that the deploying identity can
  resolve the profile is made explicit about **root's** copy, so the operator's
  credential is an addition to the loop's precondition, not a replacement for
  it.

## Impact

- **Files**: `hosts/netcup/operator.nix` (the wrapper and the activation seed),
  `hosts/netcup/self-deploy.nix` or `devenv.nix` (the seed source path, if a
  system-side half is needed), a seeding script under `scripts/`, `specs` as
  above. No `devenv.yaml`, `devenv.lock` or `secretspec.toml` change is
  anticipated — the declaration already exists.
- **Host**: `hbohlen` gains `~/.config/op-sa-token` and a `gh` wrapper;
  activation (re)creates both on every deploy, and the wrapper is a
  home-manager file, so it survives a rebuild. Root's half is untouched.
- **Vault**: unchanged — read only, no new item, no write, no rotation.
- **A second at-rest copy of the service-account token exists** on the host
  (under `hbohlen` instead of only root). The design names this as the direct
  cost of the change, and records why it is accepted: the credential is
  read-only, and the alternative is an operator account that cannot
  authenticate.
- **Reference honesty**: relative to `~/projects/nixos` — this *narrows*
  ADR-0005's blast-radius posture by adding one at-rest credential under the
  working account, and says so; it does not inherit any of that repo's
  credential design.
