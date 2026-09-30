# nix — netcup host and workstation shell

One devenv root project with two halves: **netcup**, a NixOS guest declared and
deployed as a devenv Machine, and the **shell layer** the operator and agents
work inside on the workstation. This file is the glossary. It says what each
term means here and which decision settled it. D-numbers point into
`.scratch/devenv-layering/map.md`.

## Language

### Layering

**Machine layer**:
Netcup's NixOS role needs six items: `target.host`, the `nixos` role, the
`disko` input, the `install.*` block, `deploy.healthCheck`, and
`deploy.rollbackTimeout`. A separate Home Manager role installs the operator's
`devenv` CLI; other development tools stay in the shell layer. (D8, D17, D51)
_Avoid_: irreducible six, server side, host config

**Shell layer**:
Everything this repo's devenv config declares. It is active while the project
is entered and gone when it exits. (D1, D2)
_Avoid_: dev env, the profile

**The four**:
`secretspec`, `nix`, `devenv`, `tailscale` — the only things a non-NixOS
machine needs before the shell layer can run. (D3, D17)
_Avoid_: prerequisites list, bootstrap set

**Portability test**:
A tool stays in the shell layer only if the layer still runs on a non-NixOS
machine given only the four. Anything that fails the test belongs in the
machine layer or nowhere. (D3)
_Avoid_: D3 test

**Placement table**:
The survey naming where every tool lives: Shell, Prerequisite, Dropped, or out
of scope. Its universe is closed — a tool earns a row only by the D18 rule.
(D18)

### Tool placement

**Durable copy**:
The native, self-managed install of a self-updating CLI. It stays on disk next
to the shell's declaration, because it is what survives a broken shell. (D9,
D20)
_Avoid_: workstation durable (D1 named this a third layer; D12 and D20
absorbed it per tool)

**Shell shadow**:
The declared copy of a tool that also has a durable copy. Inside the project,
the shadow is authoritative. (D9, D20)
_Avoid_: duplicate, override

**Trap**:
An unmanaged copy on PATH that hijacks the declared one. The nix profile's
nushell 0.113.1 beating the declared 0.115.1 was the worked case. (D6, D40)
_Avoid_: stale binary

**The wrapper**:
`bin/devenv` in this repo, pinned to 2.4.0, which is the only version with
`machines`. On the workstation, bare `devenv` is the profile's 2.2.2 and is
always wrong inside this project. On netcup both names are 2.4.0. (D6)
_Avoid_: pinned devenv

**Source rule**:
Per tool, not per class: agent CLIs come from the pinned `llm-agents` input,
everything else from the locked nixpkgs, and `openspec` is the named exception
that comes from nixpkgs. (D25, D30)

### Install and deploy

**Install**:
First provisioning of netcup: `devenv machines install` images the host,
partitions with disko, and enrolls the tailnet on first boot.
_Avoid_: setup, bootstrap (bootstrap is reserved for the token file, below)

**Deploy**:
Every later update of netcup: run `devenv machines plan netcup`, review its
outputs, then run `devenv machines apply plan-REPLACE_WITH_ID`. NixOS gets a
health check and automatic rollback; the CLI-only Home Manager role does not.
(D8, D51)

**Promotion**:
A shell-scoped prototype moving into netcup's machine layer, as part of the
deploy. Caddy is the current candidate. (D15)
_Avoid_: migrate, graduate

**Successor**:
The shell's copy of a definition the machine still serves. The shell
Caddyfile is the successor of `/etc/caddy/Caddyfile`; the machine copy retires
at promotion. (D24)
_Avoid_: replacement, takeover

### Shell identity

**Login shell**:
zsh, on the workstation. It sources `/etc/profile` and the nix profile
scripts. Nu never becomes this. (D26)

**Project shell**:
nu, inside the devenv shell — interactive, and the shell every new pane
spawns. Scripts and devenv tasks stay bash. (D26, D29)
_Avoid_: interactive shell vs agent shell (there is one project shell; both
use it)

### Ingress

**Ingress**:
Caddy with a Cloudflare DNS-01 certificate, bound to the tailnet address,
serving `hermes.hbohlen.space` and `hermes-gateway.hbohlen.space`. The only
domain is `hbohlen.space`, under the wildcard that already resolves here.
(D11, D16, D32)
_Avoid_: reverse proxy (use it only for the Caddy process itself), tunnel

**dsh endpoint**:
The one ingress site served PORT-LESS, because the dsh session cookie is bound
to `hostname:port`: the system Caddy on tailnet `:443` answers
`dsh.hbohlen.space`, sending tokenless root visits through the loopback
redirector (`dsh/phone-entry.py`) to the current launch token and proxying
everything else to `127.0.0.1:3080`. Its facts — port, entry port, home,
public name — are declared as `dsh.*` options in `modules/dsh.nix`, and every
consumer interpolates them; no copy survives elsewhere in the tree. This repo
declares the upstream and the redirector, not the system route; promotion to
netcup moves both. (D42, ADR 0011)
_Avoid_: dsh site on a high port (the `:9445` shape was removed)

**Host profile**:
The `profiles.hostname.<name>.module` block in `devenv.nix` that selects one
host's facts and behavior: the measured `host.tailnetIp` / `host.tailnetName`
(`modules/host.nix`, ADR 0011) and the ingress decisions — HTTPS ports, and
whether it owns the port-less dsh route (`ingress.*`). `contabo` is the
9443/9444 prototype; `netcup` is port-less 443 plus the dsh route. devenv
picks the block from the running hostname, so the same modules configure the
right ingress with no flag and no local file. (D50)
_Avoid_: per-machine config, environment

### Secrets

**Token file**:
`~/.config/op-sa-token`, the source of `OP_SERVICE_ACCOUNT_TOKEN`. The shell
rc exports it before the hook (the bootstrap), and the activation environment
carries it into panes. It must not flow through `secretspec` — `secretspec`'s
1Password provider is what needs it, so that route is circular. (D36, D39)
_Avoid_: op token, SA token

**Render**:
Producing a runtime secret FILE from a `secretspec.toml` manifest with an
imperative command (`secretspec export --format dotenv > $HERMES_HOME/.env`),
outside the devenv integration. The word distinguishes it from resolution:
devenv never resolves secrets for the shell layer, and no secret value ever
enters a Nix evaluation or the store. (D45, ADR 0007, ADR 0010)
_Avoid_: inject, load, resolve-from-devenv

**Resolution opt-in**:
The per-invocation choice to let `machines`/`eval` commands contact the vault,
via `SECRETSPEC_PROVIDER`/`SECRETSPEC_PROFILE` (+ `SECRETSPEC_REASON`). Never
a standing config: `secretspec.enable` is false in every `devenv.yaml`,
because with a manifest in the tree `enable: true` resolves the profile at
every command load. (D45, ADR 0010)
_Avoid_: secretspec enabled globally, enable=true

### Docs and process

**Runbook**:
An operator-facing doc in `docs/`. Every claim in one is true against the tree
now, never aspirational. (D10)

**Research report**:
Dated evidence with verbatim upstream quotes, in `docs/research/`. (D10)
_Avoid_: notes, findings doc

**Doc rule**:
Edit a doc when a claim in it is false against the tree. Delete it only when
its subject is finished. Leave it when it records a decision still in force.
(ticket 04, D41)

**Map**:
The wayfinder chart at `.scratch/devenv-layering/map.md`. It holds decisions,
not deliverables, and is untracked on purpose. (D41 records the one hand edit
made to `docs/` outside it.)

**D-number**:
One settled decision, listed under "Decisions so far" in the map. Cited
everywhere else by it.
