# netcup

One NixOS machine, declared in this repository and deployed **to itself** with
[devenv machines](https://devenv.sh/machines/). The checkout lives on the
machine at `/home/hbohlen/nix`, and everything — edit, eval, commit, push,
deploy — happens there, as `hbohlen`.

## The loop

    cd /home/hbohlen/nix
    <edit hosts/netcup/*.nix>

    # 1. eval: does it build, and what system path does it produce?
    SECRETSPEC_REASON="iterate: eval" \
      OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) \
      ./bin/devenv eval machines.netcup.build.nixos --no-tui

    # 2. commit and push (the gate refuses an unpublished commit)
    git add -A && git commit -m "<action> | <subject>"
    OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) \
      secretspec run -- git push origin main

    # 3. gate, then deploy
    ./scripts/self-deploy-drift.sh      # must print NO DRIFT
    bash scripts/self-deploy-run.sh     # build -> activate -> read the status back

`self-deploy-run.sh` is the deploy: it exports `NIX_SSHOPTS`,
`SECRETSPEC_REASON` and the token, proves the loopback login first, evaluates,
deploys transactionally against `root@localhost`, then reads `machines status`
back and checks that the running system is the one it asked for.

The declaration in `devenv.nix` names the **public** address as the target, so
the same file still works for a deploy driven from another machine; the
`-O machines.netcup.target.host:string root@localhost` override inside the
scripts redirects that invocation only.

## Credentials

| what | where | used for |
|---|---|---|
| service-account token (read-only, 1Password `dev`) | `~/.config/op-sa-token`, 0600 (root's copy: `/root/.config/op-sa-token`) | every `devenv machines` / `eval` call; `secretspec run` |
| loopback SSH key | `~/.ssh/id_ed25519-op-dev`, 0600 | authenticating as `root@localhost` for the deploy |
| `GH_TOKEN` | vault only — `secretspec run -- git push` | GitHub, per invocation, never at rest (`~/.config/gh` does not exist) |

Every `devenv machines` / `devenv eval` call also needs `SECRETSPEC_REASON`
(`require_reason = true` in `secretspec.toml`), or it dies with a reason error
that reads like a machine error.

**The sudo boundary does not separate `hbohlen` from these secrets.** The key
and the token sit in that user's home at 0600; anything running as `hbohlen`
can use them directly. No privilege was gained — passwordless sudo was already
in place — but the boundary is no longer where it was.

## Facts that cost a failure

* **`/bin/bash` does not exist** on NixOS. The scripts use
  `#!/usr/bin/env bash`; run them as `./scripts/x.sh` or `bash scripts/x.sh`.
* **The host has no `python3`.** The scripts parse JSON with grep/sed/awk on
  purpose — a parser that needs python3 passes in a shell that happens to carry
  it and fails everywhere else.
* **A failed activation rolls back on its own**: the previous system comes back,
  `machines status` reports `phase: rolled-back`, and the host keeps answering
  SSH. `devenv machines rollback` exists as a manual path but is not usually
  needed.
* **Never run bare `devenv update`** — it moves the pinned `devenv:` input off
  its release tag, away from the binary `bin/devenv` was built against. Update
  inputs by name.
* **`/nix/store` is remounted read-write at boot** by
  `nix-store-remount-rw.service`. If a build fails with a read-only store, that
  unit is the first suspect, not nix.
* **Both root SSH and the loopback key are load-bearing.** The deploy targets
  `root@localhost` with that identity, so closing root login or the loopback
  path closes the loop with it.

## Layout

    devenv.nix         the Machine: target, client identity, install secrets, module imports
    devenv.yaml        inputs (devenv v2.4.0, disko, home-manager, llm-agents) + secretspec
    devenv.lock        the pins
    hosts/netcup/      the NixOS configuration
                         default.nix     users, sshd, bootloader, assertions
                         disko.nix       disk layout (source of every fileSystems entry)
                         hardware.nix    the hand-written hardware facts
                         tailnet.nix     overlays, no firewall change
                         self-deploy.nix nix settings, caches, git, the loop record
                         operator.nix    the operator's home-manager role
                         agents.nix      hermes-agent + herdr
    secretspec.toml    secret declarations; values live in the 1Password `dev` vault
    bin/devenv         pinned devenv 2.4.0 (with its cachix substituter flags)
    scripts/           self-deploy-drift.sh — the gate before a deploy
                       self-deploy-run.sh — the deploy itself

## History

The install and tailnet runbooks, the host verifiers, the workstation entry
points, the openspec change records and the handoff notes were all removed for a
clean slate. Nothing is lost: the full tree before that clean-up is commit
`9831963`, and every file is reachable from it.
