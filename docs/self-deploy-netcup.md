# netcup rebuilds itself

The procedure of record for `openspec/changes/add-netcup-self-deploy`, and the
runbook form of its tasks groups 5-8. Read with `docs/install-netcup.md`, which
covers the first install, and `docs/tailnet-netcup.md`, which covers the overlay.

**What the loop is.** The host holds a checkout of this repository at
`/home/hbohlen/nix` and rebuilds itself from it over its own loopback:

    on the host:  ./bin/devenv machines deploy netcup \
                    -O machines.netcup.target.host:string root@localhost --no-tui --yes

The `-O` override redirects **that invocation only**; the declaration in
`devenv.nix` still names the public address, so the same file is correct for a
deploy run from the workstation. No workstation, no vault session, and no
long-lived vault credential are in the loop.

## 1. Which remote, and who pushes

The remote is `origin = https://github.com/hbohlen/nix.git`, branch `main`. The
repository is **public**, which is what lets the host clone and pull with no
credential at all.

**THE HOST CAN PUSH NOW, AND THAT IS ALSO MEASURED (2026-09-28, host-first
session).** The older finding this replaces was taken as **root**, with no
credential helper anywhere:

    root@netcup:~# git -C /home/hbohlen/nix push --dry-run origin main
    fatal: could not read Username for 'https://github.com': terminal prompts disabled

That is still what a bare `git push` as root does. What changed is that the user
who actually works on this host now has a credential path:

    OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) \
      secretspec run -- git push origin main

`gh auth setup-git` installed the git credential helper, and `secretspec run`
supplies `GH_TOKEN` from the 1Password `dev` vault **for that invocation only**:
there is no `~/.config/gh`, and `gh auth status` with no environment reports no
login at all. Measured: four commits pushed from this host and read back from
the GitHub API.

So the division of labour is **edits are authored wherever the operator is —
this host or the workstation — and pushed from there**; the host pulls *and*
pushes. Risk R5 is still answered by the drift check in section 4, which makes
any uncommitted edit on the host visible and stops the loop before it builds a
system nobody can reproduce: commit and push before deploying, and the check
stays green. What the check no longer refuses is a host-side *commit*, because
that commit can now be published.

The branch is declared once, in `/etc/netcup-self-deploy/loop.json`
(`hosts/netcup/self-deploy.nix`), and `scripts/self-deploy-preflight.sh` gate 10
asserts that the scripts' `BRANCH` default and that file agree.

## 2. Preconditions

On the **workstation**: the vault session (`OP_SERVICE_ACCOUNT_TOKEN`), the
identity at `~/.ssh/id_ed25519-op-dev`, and the pinned `bin/devenv`.

On the **host** (all of it declared, all of it read back by
`scripts/self-deploy-verify.sh`):

| precondition | declared in | why the loop dies without it |
|---|---|---|
| `/nix/store` mounted `rw` | `nix-store-remount-rw.service` | the host can receive closures but not build one (R11) |
| `experimental-features = nix-command flakes` | `nix.settings` | no `nix-command`, no non-interactive build |
| `git` | `environment.systemPackages` | no checkout |
| `_1password-cli` | `environment.systemPackages` | SecretSpec's 1Password provider is a wrapper around `op`, so no `machines` command runs at all |
| the credential at `/root/.config/op-sa-token` (root `0600`) and the operator's copy at `~/.config/op-sa-token` (operator `0600`, added 2026-09-28) | task 6.1; the operator copy with the host-first loop | the profile cannot resolve — whichever user runs the command needs a readable copy |
| the loopback identity at `/home/hbohlen/.ssh/id_ed25519-op-dev`, operator `0600` (was root `0600` until 2026-09-28) | task 3.3 (design D4); owner moved with the loop | `root@localhost` refuses the client |

Run the workstation-side gates first. They touch nothing on the host:

    ./scripts/self-deploy-preflight.sh

Ten gates, in order: the bundled resolver, exactly one Machine, the declared
target and identity path, the closure **built** (not merely evaluated), the nix
features, `git` and `op` inside the built system, the remount unit's `ExecStart`,
both of root's public halves and no private key material in the tree or the
store, the firewall facts unchanged, and the loop record agreeing with the
scripts. It ends by naming the three host-touching steps below.

## 3. The loop

The loop runs **on this host, as `hbohlen`, with no pane and no second
machine** — that is the host-first form (2026-09-28). The workstation form
below it still works and is kept, because a pane is the right place for a deploy
you want to watch; but `bb` and `jj` are NOT installed on this host, so any step
naming them is workstation-only.

**Step 1 — edit.** `hosts/netcup/*.nix`, or the scripts. The checkout is
`hbohlen`-owned, so edit as that user (`sudoedit hosts/netcup/default.nix`, or
any editor run as `hbohlen`); root is not involved.

**Step 2 — commit and push, from wherever you edited.**

On this host (`jj` is not installed here — git is):

    git add -A
    git commit -m "<action> | <subject>"
    OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.config/op-sa-token) \
      secretspec run -- git push origin main

On the workstation:

    jj describe -m "<action> | <subject>"; jj bookmark set main -r @; jj git push -b main

**Step 3 — the loop.**

On this host, directly:

    ./scripts/self-deploy-drift.sh      # strict: must be green before a deploy
    bash scripts/self-deploy-run.sh     # build, activate, read the status back

On the workstation, in a pane, so the operator watches it:

    ./scripts/bb-pane-run.sh --title "self-deploy from the host" -- \
      ./scripts/self-deploy-host.sh

That entry script, in order:

1. `self-deploy-drift.sh --fast-forwardable` — the host must be **clean**, and
   the published revision must descend from what it holds. `BEHIND` is fine here
   and normal: a push just happened, and step 2 fixes it. Dirty work and
   unpublished host commits stop the run.
2. `git pull --ff-only` on the host, then the **strict** drift check again.
3. `bash scripts/self-deploy-run.sh` **on the host**, over ssh — the deploy
   itself, with `NIX_SSHOPTS`, `SECRETSPEC_REASON` and
   `OP_SERVICE_ACCOUNT_TOKEN` set (see section 6). It prints the running system
   before and after, and reads `machines status` back with the same override.
4. The verdict, read from the host.

A healthy run is short and looks like this (2026-09-28, a real change:
`Closure: +4 / -3 store paths`, `copying 0 paths...` — the host built it itself):

    netcup: deployed
      deploy exit 0
      "phase": "succeeded", "outcome": "succeeded"
      OK   the running system is the one this run requested
    SELF-DEPLOY OK: the host built and activated its own declaration.

**Step 4 — verify.**

On this host (no pane — `bb` is not installed here):

    ./scripts/self-deploy-verify.sh

On the workstation, in a pane:

    ./scripts/bb-pane-run.sh --title "host preconditions" -- ./scripts/self-deploy-verify.sh

Read-only, over the public path: the host answers as root **and** as the
operator (from the workstation as a live login; from the host, where that key
does not exist, as the authorized-keys configuration — both are the same
question, answered with what the caller can prove); the checkout is the
published revision; the nix features, `git` and
`op` are installed; the store is `rw` and the remount unit's `Result=success`;
the loopback identity's mode and fingerprint; a loopback login with no agent; a
store over the loopback answering a question about the running system; the
credential's mode and sha256 prefix on both machines (the value is never read
out); the loop record in the running system; and `machines status` reporting
`phase: succeeded` with `requestedSystem` equal to `/run/current-system` — what
the last run asked for is what runs. (This line used to read
`previousSystem == requestedSystem`, which only holds while every deploy is a
no-op; the first real change of 2026-09-28 disproved it, and the verifier now
asserts the running system instead.)

## 4. The drift check

    ./scripts/self-deploy-drift.sh                    # strict: read before a deploy
    ./scripts/self-deploy-drift.sh --fast-forwardable # the state right after a push

Strict mode exits 0 only when the host **is** the published revision with nothing
uncommitted. `--fast-forwardable` treats `BEHIND` as a note and still fails on
dirty work or unpublished commits. Both compare against the **remote**
(`git ls-remote`), not against a local bookmark — "the published revision" is
what a fresh clone would get.

The commit ranges are read with the **workstation's** object store. A host that
is behind has not fetched the published revision, so `git log HEAD..origin/main`
on the host prints nothing even when commits are missing — measured on this
check's first real run, which is why its first version printed an empty list
under a FAIL.

## 5. Rollback, and testing it deliberately

A deploy is transactional: if activation fails, the previous system is restored
in place. Measured 2026-09-28, deliberately, with an uncommitted probe unit on
the host (`ExecStart = coreutils/false`, wanted by `multi-user.target`):

    × Fleet deployment stopped. Completed: none.
      netcup: Transaction deployment-vAyIhUZ8cIHwuxr97U4uFOvo was rolled back on
      netcup: Command '[.../switch-to-configuration', 'switch']' returned non-zero
      exit status 4.
      "phase": "rolled-back", "outcome": "rolled-back", "error": "…exit status 4."

Afterwards: `previousSystem` was running again, `systemctl is-system-running` was
`running`, the probe unit was gone, and the host answered SSH on **both**
channels — the public address and the tailnet overlay, which was confirmed
reachable *before* the probe (risk R3). 304 s end to end: that is the
transaction's window, not a hang.

The procedure, which is task 7.5:

    # 0. the second channel, before anything fails
    ssh -i ~/.ssh/id_ed25519-op-dev root@nc.worm-hue.ts.net hostname

    # 1. the probe: uncommitted ON THE HOST
    ssh root@152.53.92.126 'cd /home/hbohlen/nix && git status --porcelain'
    #    ... append a unit whose ExecStart fails ...

    # 2. the check MUST fail on it — this is half of task 8.3
    ./scripts/bb-pane-run.sh --title "drift" -- ./scripts/self-deploy-drift.sh

    # 3. deploy the probe on purpose, and watch the rollback
    ./scripts/bb-pane-run.sh --title "rollback probe" -- \
      ./scripts/self-deploy-host.sh --probe-uncommitted

    # 4. discard the probe, and confirm the check goes green again
    ssh root@152.53.92.126 'git -C /home/hbohlen/nix checkout -- .'
    ./scripts/bb-pane-run.sh --title "drift" -- ./scripts/self-deploy-drift.sh

    # 5. and the loop still deploys, with no re-image
    ./scripts/bb-pane-run.sh --title "self-deploy" -- ./scripts/self-deploy-host.sh

`--probe-uncommitted` is the **only** door through the dirty gate: it passes
`--allow-dirty` to the drift check, loudly and naming the paths, and it does NOT
relax the revision check. No other reason to use it. `machines rollback` exists
as a manual path but is not needed — a failed activation rolls back on its own.

## 6. Measured facts that cost a failure

* **THE HOST HAS NO `python3`.** `hosts/netcup/self-deploy.nix` adds `git` and
  `_1password-cli` and nothing else, so a host-side script may use `coreutils`,
  `sed`, `grep` and bash builtins — and nothing more. The first run of
  `self-deploy-run.sh` died with `python3: command not found`, which reads like a
  broken eval.
* **`hostname` IS NOT ON A NON-INTERACTIVE SSH PATH.** The NixOS `hostname`
  binary lives in `/run/current-system/sw/bin`, which a commanded ssh session has
  only when the caller's environment is not forwarded. Measured: the same remote
  command reported `hostname: command not found` when it was. `self-deploy-run.sh`
  reads `/proc/sys/kernel/hostname` with the `read` builtin instead.
* **THREE VARIABLES, THREE FAILURES THAT LOOK LIKE A BROKEN HOST.** Without
  `NIX_SSHOPTS` the store copy over `ssh://root@localhost` is refused (R9, and
  the declaration pins `-i` + `IdentitiesOnly=yes`, so no other key path is
  visible); without `SECRETSPEC_REASON` `machines` dies at
  `require_reason = true`; without `OP_SERVICE_ACCOUNT_TOKEN` the provider fails
  in a way that reads like the machine's fault. The token is read from
  `/root/.config/op-sa-token`, root `0600`, and never printed.
* **`nix store info` PRINTS ONLY THE STORE URL** (Nix 2.34.8) — no `Version:`,
  no `Writable:`; `nix store ping` is the same command under a deprecation
  warning. A verifier that waits for those lines fails on a working host. The
  check proves the store *answers* (exit 0) and answers a question:
  `nix path-info --store ssh://root@localhost $(readlink -f /run/current-system)`.
* **AN OLD SYSTEM PATH IS NOT DRIFT.** `/nix/store` keeps the previous
  `nixos-system-netcup-*` path after a successful deploy; the fact to compare is
  `readlink -f /run/current-system`.
* **NO ROOT LOGIN IS CLOSED HERE.** `PermitRootLogin = prohibit-password` stays,
  because Machines' install and deploy paths need root SSH, and the loopback key
  is a root key. Closing it is the hardening change's work, and it will close
  the routine deploy path — see `docs/handoff-followups.md` §3.

## 7. What this procedure deliberately does not do

* No firewall or sshd change, no `Match Address` restriction: the loop needs
  `127.0.0.1` reachable as root until hardening says otherwise (R7).
* No jj on the host: building and deploying need git only.
* No push credential on the host (section 1).
* No re-image on a failed deploy: the rollback path is the recovery path, and it
  was exercised (section 5).