# The shell layer — operator runbook

The daily path for working in this repository. The **shell layer** is everything
[`devenv.nix`](../devenv.nix) declares for the workstation: the toolset, the
languages, nushell, and the prototype processes. It is active while the project
is entered and gone when it exits (D2). The words here are
[`CONTEXT.md`](../CONTEXT.md)'s; each claim is true against the tree now, per the
doc rule (ticket 04, D41).

The machine half of this repository — netcup — has its own runbook,
`docs/netcup.md`, which lands with ticket 08. The dsh Web endpoint has its own:
[`dsh-web-endpoint.md`](./dsh-web-endpoint.md).

## 1. Prerequisites — the four

The shell layer runs on a non-NixOS machine given only these four (D3, D17):

| # | Prerequisite | Why it cannot live in the layer |
|---|---|---|
| 1 | `nix` | builds and evaluates the layer |
| 2 | `devenv` | activates the layer; the version pin is `bin/devenv`'s job |
| 3 | `tailscale` | the ingress binds the tailnet address |
| 4 | `secretspec` | resolves the vault on the **machine** path (D45) |

Nothing else is required, and that is an audited result, not an aspiration —
ticket 07 proved it and D45 records the one real dependency it removed.

```console
$ for t in nix devenv tailscale secretspec; do command -v "$t"; done
```

Expected: four paths. If `devenv` here is not 2.2.2 or older on a workstation,
that is fine — inside the project `bin/devenv` (pinned 2.4.0) is authoritative,
per step 2.

**Build the pinned toolchain once, after cloning.** `bin/devenv` execs
`.devenv-toolchain`, which is a gcroot and never tracked. Without it every
`bin/devenv …` call stops with a rebuild instruction:

```console
$ nix build 'github:cachix/devenv/v2.4.0#devenv' --out-link .devenv-toolchain \
    --option extra-substituters https://devenv.cachix.org \
    --option extra-trusted-public-keys "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
$ ./bin/devenv --version
devenv 2.4.0+b904dcb (x86_64-linux)
```

The substituter flags matter: without them nix compiles devenv's Rust workspace
instead of fetching it. Rebuild with the same command if the gcroot is
collected.

## 2. The login shell — zsh sets up, nu takes over

Two shells, deliberately (D26):

- **The OS login shell is zsh.** It is what sources `/etc/profile` and the nix
  profile scripts; nu cannot, so nu never becomes it.
- **The project shell is nu.** `shell: nu` in
  [`devenv.yaml`](../devenv.yaml) makes nu the interactive shell *inside* the
  project, and the shell every new pane spawns (D29).

Three blocks in `~/.zshrc` make that work. They are a workstation dotfile, not
part of this repository — this section is what reproduces them on a new
machine.

**a. The token bootstrap, BEFORE the hook** (D39):

```zsh
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" && -r "$HOME/.config/op-sa-token" ]]; then
  export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.config/op-sa-token")"
fi
```

See step 3 for why the order is not negotiable.

**b. `~/nix/bin` first on PATH, then the hook** (D6, D38):

```zsh
if [[ -d "$HOME/nix/bin" ]]; then
  path=("$HOME/nix/bin" ${path:#"$HOME/nix/bin"})
  export PATH
  eval "$(devenv hook zsh)"
fi
```

Order matters twice: `~/nix/bin` goes **first** so bare `devenv` is the pinned
2.4.0 instead of the global profile's older binary, and the hook is sourced
**after** that because the hook shells out to `devenv`. The `zsh` hook, not the
bash one — the hook protocol passes a shell hint that tells devenv which dialect
to emit.

Nothing auto-activates without trusting the directory. `devenv allow` records
`~/nix` in `~/.local/share/devenv/allowed`; the hook stays quiet elsewhere by
design.

```console
$ devenv allow          # inside ~/nix
$ cat ~/.local/share/devenv/allowed
{"path":"/home/hbohlen/nix"}
```

**c. No `.envrc`, no direnv.** Auto-activation is the native hook (D6), and
`direnv` is not a prerequisite.

## 3. The token bootstrap, and why it comes first

`~/.config/op-sa-token` (0600) holds the 1Password service-account token. Its
consumer on this path is `secretspec`, whose 1Password provider is a wrapper
around the `op` binary — so the token cannot itself arrive through
`secretspec`. That circularity is why the file stays the source (D36).

**Since ticket 07/D45 the shell does not resolve SecretSpec at all.**
[`devenv.yaml`](../devenv.yaml) sets `secretspec.enable: false`, so `devenv shell` and
`devenv test` enter on the four prerequisites alone — with neither the token
nor a reason. The export is now a **convenience**: panes spawned from an
already-activated shell can run `secretspec run` or `devenv machines` without
re-reading the file. [`modules/shell.nix`](../modules/shell.nix)'s `enterShell` re-exports it into the
activation environment for exactly that reason.

The vault is a **machine-path** concern. The `eval` and `machines` steps opt in
per invocation with `SECRETSPEC_PROVIDER=dev SECRETSPEC_PROFILE=default`, and a
`SECRETSPEC_REASON` is mandatory (`require_reason = true` in
[`secretspec.toml`](../secretspec.toml)). The deploy loop in
[`README.md`](../README.md) is the worked example.

The value must never become a Nix `env` entry or a path literal: either would
copy the secret into the world-readable store (ADR 0007).

```console
$ ls -l ~/.config/op-sa-token
-rw------- 1 hbohlen hbohlen … /home/hbohlen/.config/op-sa-token
```

## 4. First entry

Open a new terminal (the zsh blocks must be sourced), then:

```console
$ cd ~/nix
$ echo "$SHELL"
/nix/store/…-nushell-0.115.1/bin/nu
```

The shell swaps to nu because [`devenv.yaml`](../devenv.yaml) declares `shell: nu`; zsh stays the
login shell and `exit` returns to it. `nu` resolves to the **declared** 0.115.1,
not a profile copy — the profile's stale `nushell` entry was removed (D40).
`command -v nu` outside the project now finds nothing, which is expected: nu is
a project tool.

Without the hook (a fresh machine, or a non-interactive caller), enter
explicitly:

```console
$ ./bin/devenv shell
```

## 5. Check it

One command is the whole acceptance:

```console
$ ./bin/devenv test --no-tui
…
  shell layer ok
✓ Tests passed :)
```

`enterTest` ([`modules/shell.nix`](../modules/shell.nix)) asserts every tool the placement table
promised is on PATH, that `devenv` on PATH is the pinned 2.4.0, and that the
shell type is one devenv accepts. A failure names the missing tool.

**If the processes are already up**, the default dotfile refuses rather than
racily restarting them. Test in isolation instead of stopping your work:

```console
$ ./bin/devenv test --override-dotfile --no-tui
```

`--override-dotfile` uses a temporary `.devenv`, so it also proves the result
does not depend on this workstation's local state (the isolation D45's evidence
used).

## 6. The processes

Four are declared. All are **session-scoped** (D15): they live as long as the
process manager, and the ingress URLs answer only while they are up.

| Process | Listens | Serves |
|---|---|---|
| `caddy` | `100.115.197.61:9443`, `:9444` | the prototype ingress |
| `hermes-dashboard` | `127.0.0.1:9119` | the dashboard upstream |
| `dsh-web` | `127.0.0.1:3080` | the dsh Web UI upstream |
| `dsh-phone-entry` | `127.0.0.1:3082` | the phone-entry redirector |

```console
$ devenv up -d                    # start everything, in the background
$ devenv processes list           # what is up
$ devenv processes logs caddy     # follow one
$ devenv down                     # stop the manager and its processes
```

The ports above are **this workstation's**. The ingress is parameterized per
host by `profiles.hostname.*` in [`devenv.nix`](../devenv.nix) (ticket 08 step 2,
D50): the `netcup` profile renders the two Hermes sites port-less on `:443` and
also declares the dsh route, while `contabo` keeps the `:9443`/`:9444` prototype
and leaves dsh to the system Caddy, which owns the port-less name (D42, ADR
0002's exception). An unprofiled host declares no ingress at all.

`dsh.hbohlen.space` is port-less. On this workstation the **system** Caddy serves
it on the tailnet's `:443` and this repository declares only the upstream and the
redirector; that route is outside this repo. On the promoted netcup host, which
has no other Caddy, the route *is* declared — `modules/ingress.nix` renders the
`@dshEntry` + `@dsh` matcher order behind `ingress.serveDsh` (D48, ADR 0008).
Full runbook: [`docs/dsh-web-endpoint.md`](./dsh-web-endpoint.md).

## 7. The checks worth knowing

```console
$ devenv tasks list
$ devenv tasks run ingress:smoke   # both Hermes sites bound on the tailnet address
$ devenv tasks run dsh:open        # prints the current token URL
$ devenv tasks run dsh:smoke       # the whole dsh chain, asserted
```

`ingress:smoke` needs the vault and the tailnet, so it is a task rather than
part of `devenv test`.

The ingress has two known gaps, both recorded in
[`modules/ingress.nix`](../modules/ingress.nix) and
ticket 06 rather than silently worked around:

- The gateway's **api_server** (`127.0.0.1:8642`) is absent, so
  `hermes-gateway.hbohlen.space:9444/v1/*` answers 502. The webhook upstream
  (`8644`) is up (re-measured 2026-09-30): `/` returns 404, not 502. The
  api_server and the gateway config live in `~/.hermes`, outside this repo.
- `hermes.hbohlen.space` still A-records to the offline tailnet node
  `zepyhrus`; repointing it to `100.115.197.61` is a Cloudflare dashboard step,
  not code.

## 8. When something looks wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to get attribute 'devenv.config.machinesMeta'` | bare `devenv` is the old profile binary | use `./bin/devenv …`, or fix the PATH order in step 2b |
| `bin/devenv: the pinned toolchain is missing` | `.devenv-toolchain` was collected | rebuild it (step 1) |
| `OnePassword authentication required` | a `machines`/`eval`/`secretspec` call without the token or reason | token from step 3; add `SECRETSPEC_REASON` |
| `devenv test` fails with the processes up | the default dotfile guards live state | `--override-dotfile` (step 5) |
| `nu` is a different version than declared | a profile `nushell` entry came back | remove it: `nix profile remove nushell` (D40) |
| the shell does not activate on `cd` | the directory is not trusted | `devenv allow` inside `~/nix` |

**Never run bare `devenv update`.** It moves the pinned `devenv:` input off its
release tag, away from the binary `bin/devenv` was built against. Update inputs
by name.

## What is not in this runbook

- **netcup** — install, deploy, rollback. Ticket 08 reduces the machine layer
  and writes `docs/netcup.md`; the deploy loop is in
  [`README.md`](../README.md) today.
- **The workload profiles** (opencode/pi/claude on the host) — `docs/` has no
  home for them yet; they are not part of this repository's shell layer.
- **The decision record** — `CONTEXT.md` is the glossary, `docs/adr/` the seven
  hard-to-reverse choices, and `.scratch/devenv-layering/map.md` the full
  untracked wayfinder chart.
