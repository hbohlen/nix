# Proposal: record-deferred-devenv-mechanisms

## Why

`docs/devenv-feature-opportunities.md` item 14 lists nine devenv 2.x mechanisms
this config deliberately does **not** use — `hardware.facter`, `install.extraFiles`
/ `install.encryptionKeys`, `install.secretspec.execution = "target"`,
`--use-machines-as-builders`, `secretspec.cachix_auth_token`, `devenv hook` +
`allow`/`revoke`, the TUI user config, `outputs`/`devenv build`, and the
`-O/--option` type limits. Each item records *why* it is deferred, but not the
**premise that would have to change** to activate it, so a future session (or
agent) re-derives the same reasoning from the live config every time — or worse,
adopts one of them on the strength of the research note alone. This change turns
that informal "revisit only if the premise changes" list into a durable decision
record: for each mechanism, the deferral decision **and the trigger** that would
flip it, each cited to the primary source that owns it.

**Milestone.** This is housekeeping on the current milestone (the host runs its
declared NixOS, with tailnet, self-deploy and operator environment), not a new
capability. It advances no new moving part; it makes the already-taken deferrals
legible so the next milestone's changes — hardening/tailnet-only access, a second
host `oci`, packaging, agent tooling — start from a record instead of a
re-derivation. It follows the precedent of the archived
`2026-09-28-reconcile-netcup-install-spec`: spec/doc-only, no config, host, or
vault change.

**Non-goals, stated explicitly:**

- **Nothing is adopted.** Every item below stays as it is today.
- **No config change.** `devenv.nix`, `devenv.yaml`, `secretspec.toml`,
  `hosts/netcup/*` and `scripts/*` are untouched.
- **No host, vault or secret is touched.** No target is contacted; no secret is
  added, resolved, created, or rotated. (The read of the live premises is
  read-only.)
- **No new capability and no spec-level requirement change.** This is a record,
  not a behaviour change; there is no `specs/<name>/spec.md` to create.
- Not deciding the access posture, hardening, `oci`, snapshots, or the
  agent-runner service model — those remain their own changes
  (`docs/handoff-followups.md` §10 ledger #3, #8, #9, #10).

## What Changes

- **`docs/devenv-feature-opportunities.md` item 14 is rewritten** from a
  conditional "revisit these only if their premise changes" list into a decision
  record: one entry per mechanism, each stating the **decision** (keep the
  current behaviour) and the **trigger** that would activate it. The owning
  primary source is cited per item, so the record can be checked without
  re-fetching the pages.
- **Per-item decisions and triggers recorded** (sources: machines page, options
  reference, ad-hoc-developer-environments page, auto-activation page, TUI page,
  outputs page, SecretSpec integration page, 2.2 blog):

  - **`machines.netcup.hardware.facter`** — `devenv.nix` sets `null` deliberately
    to keep `nixos-facter-modules` out of the graph; `hardware.nix` is
    hand-written. Trigger: a **re-image or a measured hardware change**, when a
    committed `.machines/netcup/facter.json` becomes the honest source and the
    report must be committed for CI/other builders. Switching is a *change in
    kind* (measured hardware entering the configuration), not a toggle. Source:
    <https://devenv.sh/machines/>.
  - **`machines.netcup.install.secretspec.execution`** — local execution today by
    design (`devenv.yaml`'s `secretspec` block): devenv resolves the value on the
    workstation and streams it over authenticated SSH. Trigger: the 1Password
    provider becoming reachable **from the kexec'd installer** (e.g. a
    service-account token on the throwaway host), which today buys nothing.
    Source: <https://devenv.sh/machines/> ·
    <https://devenv.sh/integrations/secretspec/>.
  - **`install.extraFiles` / `install.encryptionKeys`** — unused. Trigger for
    `extraFiles`: the first **non-secret bootstrap file** that must exist before
    first boot. Trigger for `encryptionKeys`: **LUKS being added** — `disko.nix`
    has no encryption by decision, and the file's own header records that as
    absent-by-omission. Source:
    <https://devenv.sh/reference/options/#machines>.
  - **`--use-machines-as-builders`** — irrelevant for one same-architecture host;
    it requires the C-Nix backend and cannot use `target.sshOpts`. Trigger: a
    **second host (`oci`) of another system** that should serve as a remote
    builder. Source: <https://devenv.sh/machines/>.
  - **`secretspec.cachix_auth_token`** — only needed for a **private** Cachix
    cache; the declared cache is the **public** `devenv.cachix.org`
    (`hosts/netcup/self-deploy.nix`), so it buys nothing. Trigger: switching to a
    private cache. Source: <https://devenv.sh/integrations/secretspec/> ·
    <https://devenv.sh/blog/2026/07/28/devenv-22-attach-to-running-processes-and-persistent-out-of-tree-environments/>.
  - **`devenv hook` auto-activation + `devenv allow`/`revoke`** — in tension with
    the "use `./bin/devenv`, never bare `devenv`" rule (`docs/handoff-followups.md`
    §6; `devenv.nix` header) and would evaluate the environment on every `cd`.
    Trigger: a deliberate move to direnv-free activation **together with** a
    resolution of the bare-vs-pinned-`devenv` split. Source:
    <https://devenv.sh/auto-activation/>.
  - **TUI user config `~/.config/devenv/config.yaml`** (`shell.prompt_prefix`,
    statusline; `devenv user-config validate`) — personal and cross-project, not
    repo state. Trigger: removing the `(devenv)` prompt prefix or statusline to
    reduce pane noise, done as a user-machine decision, not a repo one. Source:
    <https://devenv.sh/tui-customization/> ·
    <https://devenv.sh/blog/2026/09/07/devenv-23-portless-and-tui-configuration/>.
  - **`outputs` / `devenv build`** — only matters when something should be
    **packaged and distributed** rather than activated; there is no consumer of a
    packaged artifact today. Trigger: the first artifact that must ship as an
    output (a package, an image, a tarball) instead of being activated. Source:
    <https://devenv.sh/outputs/>.
  - **`-O/--option`** — already used for the `target.host` loopback override;
    confirmed that the supported type list (`string, int, float, bool, path, pkg,
    pkgs`) **cannot** replace a string list, so `target.sshOpts` is not
    per-invocation overridable (`devenv.nix` records the same finding). Trigger:
    none expected — the type list would have to grow a list-typed option. Source:
    <https://devenv.sh/ad-hoc-developer-environments/>.
- **The record is explicit that nothing above is adopted and nothing changes**,
  and that each premise above was re-confirmed read-only against the live config
  (`devenv.nix`, `devenv.yaml`, `hosts/netcup/disko.nix`,
  `hosts/netcup/self-deploy.nix`, `docs/handoff-followups.md` §6,
  `openspec/config.yaml`).

## Capabilities

### New Capabilities

- **None.** This change introduces no spec-level capability. It is a decision
  record (doc-only), the same shape as the archived
  `2026-09-28-reconcile-netcup-install-spec` precedent, which was spec/doc-only
  with no config, host, or vault change.

### Modified Capabilities

- **None.** No existing capability's requirements change: nothing in
  `netcup-disk-layout`, `netcup-install`, `netcup-machine`, `netcup-operations`,
  `netcup-self-deploy` or `netcup-tailnet` is adopted, dropped, or restated, and
  the open changes' introduced capabilities (`netcup-operator-env`,
  `netcup-task-graph`, `netcup-config-module`) are untouched. Listing none is
  deliberate, not an omission.

**Where the record lands.** The deferral decisions live where the research that
produced them already lives: **`docs/devenv-feature-opportunities.md`** (item 14
rewritten as the decision record). If the record needs a repo-wide rule — that it
is authoritative for these mechanisms and must be updated when a premise changes
— that rule belongs in **`openspec/config.yaml`'s `CONVENTIONS`**, not in a spec
capability. Design and specs phases will decide whether any such pointer is
warranted; this proposal commits to the doc as the record's home.

## Impact

- **Files:** `docs/devenv-feature-opportunities.md` (item 14 rewritten); possibly
  a one-line pointer in `openspec/config.yaml` `CONVENTIONS` if the design judges
  it earned, plus this change's own artifacts. No other file.
- **Config / host / vault / toolchain:** **none.** No `devenv.nix`, `devenv.yaml`,
  `secretspec.toml`, `hosts/netcup/*`, or `scripts/*` edit; no task contacts the
  target, the Nix store, or 1Password, so no eval-or-check gate is required
  before anything. No secret is added, so the every-`machines` profile-resolution
  cost is unchanged on both machines.
- **Specs:** unchanged. `openspec validate` on the existing six specs is
  unaffected; this change adds no delta spec and modifies no canonical spec.
- **`~/projects/nixos` (a REFERENCE, never inherited by copying):** this change
  **drops and contradicts nothing** there. The previous implementation carries no
  `facter`, `extraFiles`/`encryptionKeys`, `install.secretspec.execution`,
  `use-machines-as-builders` or `cachix_auth_token` decision to inherit or
  overturn (its ADRs 0001–0006 do not address these mechanisms), and no decision
  from it is reused here. The record is about *this* build's premises, and it
  explicitly does not import the previous repo's module split or ADRs.
- **Consequences for later changes:** none are bound. Each future change that
  activates an item above updates the record at that point; the record is the
  thing that tells it which premise it changed.
