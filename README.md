# nix — the netcup machine and the workstation shell

One devenv root with two halves. **netcup** is a NixOS guest declared here and
deployed with [devenv machines](https://devenv.sh/machines/). The **shell layer**
is everything this repo declares for the workstation you work from: agent CLIs,
languages, nushell, and the prototype ingress. The glossary is `CONTEXT.md`; the
decisions behind it are `docs/adr/`.

The host deploy loop runs on the host itself. The checkout lives at
`/home/hbohlen/nix`, and everything — edit, eval, commit, push, deploy — happens
there, as `hbohlen`. After the workstation's first post-install plan and apply,
Home Manager puts the pinned `devenv` CLI on `hbohlen`'s PATH. Use the
workstation's `./bin/devenv` for installation and that first plan/apply.
`machines install` installs NixOS only.

## Operator daily path

On the workstation, `cd ~/nix` activates the shell layer by itself (the zsh
hook, `~/nix/bin/devenv` pinned to 2.4.0). Inside the project shell you get nu,
the declared tools, and the ingress/dsh processes. **`docs/shell.md` is the
runbook**: the four prerequisites, the login-shell setup, the token bootstrap
order, first entry, and the checks.

```console
$ cd ~/nix
$ ./bin/devenv test --no-tui      # shell layer ok / Tests passed :)
```

`bin/verify` re-measures the facts the comments record. It runs a Nix syntax
sweep over the tracked Nix files, `devenv test`, `ingress:smoke`, and
`dsh:smoke`. It stops at the first failing check and prints which checks passed
before that failure. To include the two smoke tasks as well, run `bin/verify`
in place of `./bin/devenv test`.

## How the docs are organized

Two kinds, per D10, and one rule for both (ticket 04, D41): **a claim goes in
only if it is true against the tree.** Edit a doc when a claim in it is false;
delete it only when its subject is finished; leave it while it records a
decision still in force.

| Where | What |
|---|---|
| `CONTEXT.md` | the glossary — the shared language, nothing else |
| `docs/adr/` | the decisions that are hard to reverse |
| `docs/` | operator runbooks: `shell.md`, `ingress.md`, `dsh-web-endpoint.md`, and (with ticket 08) `netcup.md` |
| `docs/research/` | dated evidence with verbatim upstream quotes, never aspirational |
| `docs/agents/` | how this repo's tracker, triage labels, and domain docs work |

The tracker is local markdown under the untracked `.scratch/` — see
`docs/agents/issue-tracker.md`. `.scratch/devenv-layering/map.md` is the
wayfinder chart for the current effort.

## The host deploy loop

    cd /home/hbohlen/nix
    <edit hosts/netcup/*.nix>

    # 1. eval: does it build, and what system path does it produce?
    devenv eval machines.netcup.build.nixos --no-tui

    # 2. commit and push (the deploy gate refuses an unpublished revision)
    git add -A && git commit -m "<action> | <subject>"
    OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) \
      SECRETSPEC_REASON="push: <what changed>" \
      secretspec run -- git push origin main

    # 3. gate: the checkout must hold the published revision, clean
    git status --porcelain                       # must print nothing
    test "$(git rev-parse HEAD)" = "$(git ls-remote origin refs/heads/main | cut -f1)"

    # 4. create and review a plan, then apply that exact plan
    export NIX_SSHOPTS="-i /home/hbohlen/.ssh/id_ed25519-op-dev -o IdentitiesOnly=yes"
    devenv machines plan netcup \
      -O machines.netcup.target.host:string root@localhost --no-tui
    # Review the NixOS and Home Manager outputs and the root@localhost target.
    # Replace the placeholder with the saved plan ID printed above.
    devenv machines apply plan-REPLACE_WITH_ID --no-tui
    devenv machines status netcup \
      -O machines.netcup.target.host:string root@localhost --no-tui
    readlink -f /run/current-system              # must equal the eval'd system path

The declaration in `devenv.nix` names the **public** address as the target, so
the same file still works for a deploy driven from another machine. The
`-O machines.netcup.target.host:string root@localhost` override on `machines
plan` records the host's loopback as the plan target. `machines apply` uses that
saved target. `machines status` still needs the override because it reads the
declared machine target again.

## Credentials

| what | where | used for |
|---|---|---|
| service-account token (read-only, 1Password `dev`) | `~/.config/op-sa-token`, 0600 (root's copy: `/root/.config/op-sa-token`) | SecretSpec resolution during `machines install` and `secretspec run`; runtime `op read` for `devenv up` |
| loopback SSH key | `~/.ssh/id_ed25519-op-dev`, 0600 | authenticating as `root@localhost` for the deploy |
| `GH_TOKEN` | vault only — `secretspec run -- git push` | GitHub, per invocation, never at rest (`~/.config/gh` does not exist) |

Every command that resolves a SecretSpec value needs `SECRETSPEC_REASON`
(`require_reason = true` in `secretspec.toml`). `devenv` forwards no reason flag
of its own, so the environment variable is the only route. With the integration
disabled, plain `machines info`, `machines status`, and `eval` run tokenless.
`machines install` resolves `TS_AUTH_KEY` for `install.secrets`. The documented
`machines plan`/`apply` sequence reviews and applies role outputs; it does not
write or refresh those install-time files. `secretspec run` resolves one-off
secrets such as `GH_TOKEN` for the push step.

The SHELL does not resolve the profile at all (D45, ticket 07; re-measured and
hardened by ADR 0010): `secretspec.enable` is false in every `devenv.yaml` —
root and sub-projects — because with a manifest in the tree, `enable: true`
resolves the profile at EVERY command load and tokenless runs abort. So
`devenv shell` / `devenv test` enter on the four D3 prerequisites alone, with
neither the token nor the reason. A fresh install selects the provider/profile
for its local bootstrap resolution. Plan/apply do not write install-time
bootstrap files. Secret FILES for runtime tools render outside the CLI
integration (`hermes/secretspec.toml` +
`secretspec export`, ADR 0010).

**The sudo boundary does not separate `hbohlen` from these secrets.** The key
and the token sit in that user's home at 0600; anything running as `hbohlen`
can use them directly. No privilege was gained — passwordless sudo was already
in place — but the boundary is no longer where it was.

## Facts that cost a failure

* **`/bin/bash` does not exist** on NixOS. Scripts use `#!/usr/bin/env bash`.
* **The host has no `python3`.** Anything that runs there parses JSON with
  grep/sed/awk on purpose — a parser that needs python3 passes where python3
  happens to exist and fails everywhere else.
* **A failed activation rolls back on its own**: the previous system comes back,
  `machines status` reports `phase: rolled-back`, and the host keeps answering
  SSH. `devenv machines rollback` exists as a manual path but is not usually
  needed.
* **Update inputs by name.** A bare `devenv update` moves the pinned `devenv:`
  input off its release tag, away from the binary version this project uses.
* **`/nix/store` is remounted read-write at boot** by
  `nix-store-remount-rw.service`. If a build fails with a read-only store, that
  unit is the first suspect, not nix.
* **Both root SSH and the loopback key are load-bearing.** The deploy targets
  `root@localhost` with that identity, so closing root login or the loopback
  path closes the loop with it.

## Layout

    devenv.nix         the Machine declaration + the workstation `imports`
    devenv.yaml        inputs (devenv v2.4.0, disko, home-manager, llm-agents) + secretspec
    devenv.lock        the pins
    modules/           the shell layer, imported by devenv.nix
                         tooling.nix     non-agent CLIs (locked nixpkgs)
                         languages.nix   runtimes replacing mise
                         agents.nix      agent CLIs (pinned llm-agents)
                         shell.nix       nu, the token export, the smoke test
                         ingress.nix     prototype Caddy ingress
                         dsh.nix         the declared dsh Web instance
    hosts/netcup/      the NixOS configuration
                          default.nix     users, sshd, bootloader, assertions
                          disko.nix       disk layout (source of every fileSystems entry)
                          hardware.nix    the hand-written hardware facts
                          tailnet.nix     overlays, no firewall change
                          self-deploy.nix nix settings, caches, git, the loop record
                          cli.nix         Home Manager's pinned devenv CLI for hbohlen
    dsh/               the dsh Web instance's seed material and runtime home
    hermes/            the hermes sub-project: its own devenv.{yaml,nix,lock},
                       modules/ (HM module + settings), secretspec.toml,
                       docs/ (SOUL.md, USER.md), .hermes/ = HERMES_HOME
    docs/              operator runbooks (shell.md, ingress.md, dsh-web-endpoint.md)
    docs/adr/          the decisions that are hard to reverse
    docs/research/     dated evidence reports
    docs/agents/       how the tracker, triage labels, and domain docs work
    secretspec.toml    secret declarations; values live in the 1Password `dev` vault
    bin/devenv         pinned devenv 2.4.0 (with its cachix substituter flags)
    bin/verify         re-measures the facts the comments record
    CONTEXT.md         the glossary

The issue tracker is `.scratch/` (untracked), not `docs/`: one effort per
directory, one markdown file per ticket, `Status:` leads. See
`docs/agents/issue-tracker.md`.

## History

The install and tailnet runbooks, the host verifiers, the workstation entry
points, the openspec change records and the handoff notes were all removed for a
clean slate. Nothing is lost: the full tree before that clean-up is commit
`9831963`, and every file is reachable from it.
