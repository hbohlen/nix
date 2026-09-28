# Design: add-netcup-operator-credentials

## Context

`add-netcup-operator-env` landed the operator's user environment and proved `gh`
authenticates **as root** (`secretspec run -- gh auth status` →
`✓ Logged in to github.com account hbohlen`). It did not make the same thing work
**as `hbohlen`**, and on 2026-09-28 that was measured directly on the host:

| Fact | Command | Value |
|---|---|---|
| Bare `gh` as the operator is unauthenticated | `ssh hbohlen@… gh auth status` | `You are not logged into any GitHub hosts. To log in, run: gh auth login` (exit 1) |
| The operator cannot read root's credential | `ssh hbohlen@… cat /root/.config/op-sa-token` | `Permission denied` |
| The operator has no at-rest `gh` credential | `ls ~/.config/gh/hosts.yml` as `hbohlen` | `No such file or directory` |
| …and no token in the environment | `echo ${GH_TOKEN:-<unset>}` as `hbohlen` | `<unset>` |
| The operator has `secretspec` on `PATH` | `command -v secretspec` as `hbohlen` | `/home/hbohlen/.nix-profile/bin/secretspec` |
| The vault provider needs a token to be non-interactive | `secretspec run … ` with the token stripped | `No accounts configured for use with 1Password CLI` |
| `secretspec run` injects resolved secrets into the child **environment** | `secretspec run -- sh -c 'echo ${#GH_TOKEN}'` (workstation) | `40`, first four `ghp_`; `TS_AUTH_KEY` also present (61) |
| `gh` reads a token from the environment natively | `gh` documents `GH_TOKEN`/`GITHUB_TOKEN` precedence over `hosts.yml` | accepted as platform behaviour; the wrapper scenario is what proves it on the host |
| SecretsSpec has cache and integration surfaces | `secretspec cache --help`, `secretspec git --help` | cache: `clear` only; git: `configure`/`login`/`logout`; `serve` is a per-parent child, no daemon |

The root credential is at `/root/.config/op-sa-token`, root-owned `0600`
(design D3 of the previous change), and the self-deploy loop resolves the
profile as root on every invocation.

**The posture this change corrects.** The previous design put the only
credential where the *loop* runs, and treated "the operator can work" as
satisfied by `gh` being *installed*. On a host where the intended working
account is `hbohlen` and root is "a formality that the loop happens to need",
that is inverted: the credential belongs to the account that works, and the
loop's copy is the second one.

## Goals / Non-Goals

**Goals:**

- `hbohlen` resolves the whole SecretSpec profile as itself, with its own
  `0600` credential, no root and no interactive prompt.
- `gh` works as `hbohlen` with the same UX as a logged-in `gh`, and **no PAT at
  rest** — no `~/.config/gh/hosts.yml`, no token in a shell's starting
  environment.
- Root's credential and the loop are provably unaffected.
- Spec truth: the credential requirement names the operator, and the loop's
  requirement names root.

**Non-Goals:** no vault write or item change; no `hosts.yml` or `gh auth login`
on the host; no `nix.conf access-tokens`; no change to root's file; no agent
runner; no `sudo` indirection.

## Decisions

| # | Decision | Chosen | Rejected |
|---|---|---|---|
| D1 | Which account gets the credential | **`hbohlen`**, as its own `0600` file; root **keeps** its copy | moving root's file to `hbohlen` (the loop runs as root and would break); only a `sudo` wrapper (passwordless wheel sudo already exists, so the indirection buys nothing and hides the credential behind a shell wrapper instead of a file mode) |
| D2 | How `hbohlen` gets the file | **activation-seeded** from a root-owned source, the `loopbackKey` pattern from `add-netcup-self-deploy`: seeded once out-of-band, (re)copied into the home by the role's activation | a Nix-store file (leaks the secret, forbidden by the config's hard constraints); `install.secrets` alone (install-only — deploy cannot refresh it, the §4.1 gap — and the host is already installed); the operator pasting it by hand (not declarative, not re-image-surviving) |
| D3 | How `gh` authenticates | **a wrapper on `PATH`** that `exec`s `secretspec run -- gh "$@"`, so the token exists only in the invoked process's environment | `~/.config/gh/hosts.yml` (below); exporting `GH_TOKEN` in a shell profile (leaks to every process, contradicts SecretSpec's runtime-loading guidance) |
| D4 | Persist the `gh` login? | **No** — the wrapper, with the trade-off recorded below | writing `hosts.yml` (D5 analysis); `secretspec cache` as a middle ground (its only subcommand is `clear`, so the cache's lifetime and at-rest form are not a controlled surface here) |
| D5 | Wrapper implementation | a `writeShellScriptBin`-style home-manager package that references the real `gh` by store path, placed on `home.packages` | aliasing `gh` in an rc file (not declarative; missing in a non-interactive ssh command, which is exactly where the check runs); a `secretspec git configure` helper (that configures **git**, not `gh`) |

### D4/D5 in full: why not persist, when the token is long-lived

The operator asked, reasonably, whether a long-lived PAT at rest is actually a
problem and what the objectively best route is. The analysis, written down so
the decision is inspected rather than inherited:

- **What persistence costs.** `gh` stores a login only in
  `~/.config/gh/hosts.yml`, plaintext YAML, protected by nothing but file mode
  on Linux (no keychain). Persisting puts a `repo`-scoped PAT at rest under the
  account that runs agents, on a public VPS — the standard VPS brute-force and
  agent-exfiltration threat model, and the exact blast radius both this repo and
  ADR-0005 chose to avoid.
- **What persistence buys.** It removes one vault round-trip per `gh` call. It
  does not add a capability: the wrapper yields the same interactive UX
  (`gh auth status`, `gh api user`, `gh pr …` all work unqualified).
- **The asymmetry.** The cost is a durable secret at rest; the benefit is
  typing saved. When the benefit is "saves typing" and the cost is "a repo PAT
  sits on a public box", the correct default is not to persist — and to record
  the flip (write `hosts.yml`, keep it `0600`) for the operator who decides the
  round-trip is worse than the risk. That flip is a one-line change to this
  decision, which is why it is named here.
- **The slow-down is bounded.** The wrapper resolves one secret per `gh`
  invocation; the vault is already on every `machines` path, so this is the
  same cost the repo already pays, scoped per command instead of per shell.

## Risks / Trade-offs

- **[R1] The token is now at rest under `hbohlen` as well as root — two copies
  where there was one.** → Named, not hidden: this is the direct cost. Accepted
  because the credential is read-only and the alternative is an operator account
  that cannot authenticate. Mitigation: `0600`, operator-owned, never printed by
  any check (digest prefix only), and revocation remains a vault action that
  does not touch the repo.
- **[R2] The activation seed must not copy the secret through the Nix store or
  a world-readable temp file.** → The seed source is a path **string**, never a
  Nix path literal (the config's hard constraint: a path literal copies its
  contents into the store); the activation uses the root-owned source directly
  and installs with `install -m600 -o hbohlen`; a check task sweeps the store
  and the home for the value.
- **[R3] The wrapper could break `gh` for a caller that expects the real
  binary's path (scripts calling `/nix/store/.../gh`).** → The wrapper is only
  what `PATH` resolves; the real `gh` stays at its store path and remains
  reachable by absolute path. A scenario asserts non-`gh` names are not
  intercepted.
- **[R4] A `gh` command run by a process that does not inherit the wrapper's
  `PATH` (systemd unit, cron) stays unauthenticated.** → True and intended: the
  wrapper is an interactive-operator affordance, not a service credential. A
  future agent-runner change (ledger #10) that needs `gh` must decide its own
  credential path; recorded as a non-goal here.
- **[R5] The operator's credential could shadow or replace root's by accident in
  a later edit.** → The `netcup-self-deploy` delta makes "the loop resolves with
  root's credential" a requirement with its own scenario, so a replacement is a
  spec violation, not a refactor.
- **[Trade-off] The wrapper adds a `secretspec` process to every `gh`
  call.** → Accepted; measured cost is one vault read, and it is the price of
  no token at rest.

## Migration Plan

1. Local, no host contact: add the wrapper package and the activation seed to
   `hosts/netcup/operator.nix`; write the seed script; eval gates
   (`machines info`, both `build` outputs) must pass before any host touch.
2. Seed the root-owned source for `hbohlen`'s token on the host (a pane step,
   guarded by the credential gate), then deploy.
3. Verify as `hbohlen`, **not root**: `secretspec check` resolves both secrets;
   bare `gh auth status` reports the account; `~/.config/gh/hosts.yml` does not
   exist; the credential file is `hbohlen` `0600`; root's file and a root-side
   `machines info` are unchanged.
4. Rollback: the wrapper is a home-manager file and the credential is a home
   file, so recovery is correcting the role and redeploying; the system half is
   untouched by this change.

## Open Questions

1. Should the seed source live under `/root` (root-owned, read by root's
   activation-run-as-hbohlen?) — the activation runs as `hbohlen`, so it cannot
   read a root-only source; the seed must therefore be readable by `hbohlen` at
   activation time, or copied by a root-side step. First eval and the first
   activation answer which; the design names the constraint rather than
   guessing.
2. Does `secretspec run` add measurable latency to `gh` in practice? If it does,
   revisit D4 with a number instead of an argument.
3. Is there value in `secretspec git configure --url github.com` as a
   complement for `git push` as `hbohlen` (today the host never pushes)? Out of
   scope; recorded so the option is not rediscovered.
