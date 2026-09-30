# SecretSpec's Doppler provider: what it is, what it costs, and the version floor it sets

**Date:** 2026-09-30
**Reporter:** the Doppler-as-provider change (ADR 0013)
**Question:** can Doppler replace 1Password as the SecretSpec provider for both
manifests in this repo, and what does that switch actually change?

Confidence tiers per `why/references/epistemics.md`: **Measured** = I ran it on
this machine today; **Direct** = the upstream source states it; **Supported** =
converging indirect evidence; **Inferred** = my reading; **Unknown** = looked and
did not find.

## 1. The blocking fact: the provider is 0.21+, and the durable CLI was not

**Direct.** "The Doppler provider reads and writes secrets in a Doppler project
over Doppler's REST API. **No `doppler` CLI is required**." —
[secretspec.dev/providers/doppler](https://secretspec.dev/providers/doppler/),
which also carries "**New in version 0.21**" as the section's own heading.

**Measured.** The version that actually answers `secretspec` on the workstation,
before and after:

| Copy | Path | Version before | Version after |
| --- | --- | --- | --- |
| Durable CLI (D3 prerequisite) | `~/.cargo/bin/secretspec` | 0.20.0 — **no Doppler provider** | **0.21.1** |
| Stale profile copy | `~/.nix-profile/bin/secretspec` | 0.12.0 | resolves into the devenv package bin → 0.21.0 |
| devenv's own package bin | `/nix/store/…-devenv-wrapped-2.4.0/bin/secretspec` | 0.21.0 | 0.21.0 |
| The shell profile | `/home/hbohlen/nix/.devenv/profile/bin/secretspec` | **absent** | absent |

Two things fall out of that table, and the second one is the reason the machine
path and the CLI path were never the same capability:

* **The durable CLI and the machine path disagreed.** devenv 2.4.0 shipped a
  `secretspec` 0.21.0 with the Doppler provider compiled in, while the `secretspec`
  an operator types is 0.20.0 and cannot speak `doppler://` at all. So
  `devenv machines` and `secretspec` were different binaries with different provider
  sets, silently. **Supported** by devenv's own `Cargo.toml` linking
  `secretspec = "0.21"`.
* **Inside a devenv shell the durable copy still wins**, because the activation
  script re-appends the user PATH after setting the profile
  (`.devenv/shell-*.sh`, the `PATH=…$PATH` line near the end). The profile carries
  no `secretspec`; the cargo copy does. Upgrading the durable CLI was therefore not
  optional bookkeeping — it is the only thing that makes the CLI able to do what the
  manifests now declare.

The 0.12.0 in `~/.nix-profile` is a **Trap** in this repo's vocabulary: a copy that
is on PATH, is older than everything, and reports a version that is true of itself
and nothing else. Retired by `nix profile remove secretspec`.

**Measured — do NOT take the upgrade from nixpkgs.** `pkgs.secretspec` evaluates to
**0.20.0** on both the locked `devenv-nixpkgs/rolling` and the **workstation's**
`<nixpkgs>`. crates.io has 0.21.1, so `cargo install secretspec --locked --force` is
the route. netcup is the exception, not this rule: its own channel is 26.11pre and
its profile copy already answers 0.21.0 (see §7).
(`--force` is required: cargo downloads 0.21.1 and then refuses to overwrite its own
existing binary, while the pipeline still reports success because the exit code
comes from `tail`.)

## 2. Auth: what the provider reads, and which token can exist here

**Direct.** Authentication is `DOPPLER_TOKEN`, "or the `token` provider credential"
— [provider credentials](https://secretspec.dev/reference/provider-credentials/)
lists `doppler | token | DOPPLER_TOKEN | 0.21+`. **Direct:** the token is sent as
`Authorization: Bearer`, never in the URI, so "the URI recorded in audit logs and
fallback-chain warnings carries no credential".

**Direct, and it corrects the plan.** The Doppler docs' token table
([API reference](https://docs.doppler.com/reference/api),
[Service Accounts](https://docs.doppler.com/docs/service-accounts)) lists four
kinds, and the plan picked one this account cannot have:

| Token | Prefix | Scope | On the free Developer plan |
| --- | --- | --- | --- |
| CLI (what `doppler login` leaves) | `dp.ct.` | account-wide read/write, tied to a user | yes, 5 per user |
| Personal | `dp.pt.` | account-wide read/write, tied to a user | yes |
| **Service token** | `dp.st.` | **exactly one project and one config** | **yes, 50 per workplace** |
| Service account | `dp.sa.` | workplace-wide, limited by grants | **No** — "Service Accounts —" in [platform limits](https://docs.doppler.com/docs/platform-limits) |

SecretSpec's own page recommends `dp.sa.` for "one SecretSpec configuration span[ning]
several configs". That is not this configuration: the URI pins `devenv/dev`, both
manifests read that one config, and a `dp.st.` is *stricter* than what was planned —
Doppler refuses it against any other config, and "Every request names its project and
config explicitly… Naming them turns that into an explicit Doppler refusal."

**Measured.** `doppler configs tokens create … --access read/write --max-age 30m`
works, which retires the plan's "grant write, then revoke" step: the migration token
expires by itself. Revocation is documented as non-reversible, so an expiring token
is the safer shape anyway. The read token is stored 0600 at `~/.config/doppler-token`
and exported by `modules/shell.nix`.

**Measured — the failure this leaves behind is legible, and it names the token kinds
back.** With no credential in the environment:

```console
warning: primary provider doppler://devenv/dev failed: Provider operation failed:
No Doppler token found. Configure the token provider credential, or set
DOPPLER_TOKEN. Any Doppler token works; prefer a service account token (dp.sa.) or a
service token (dp.st.), because Doppler does not serve a 'restricted' secret's value
to a personal (dp.pt.) or CLI (dp.ct.) token.; will try fallback chain for affected
secrets
Error: × Failed to get secret
```

The "will try fallback chain" line fires even with a single provider declared, and the
error still arrives after it — no silent success. The message independently
corroborates both the table above and the `restricted` rule below it: upstream itself
steers a machine path onto `dp.st.`/`dp.sa.` because a user-identity token cannot read
a restricted value.

**Direct, and it is why the token stays out of the manifest.** `restricted`-visibility
secrets are withheld from any token tied to a user identity, and SecretSpec reports
that as a refusal rather than as an unset secret — "Reporting it as unset would let
`secretspec check` offer to set — and overwrite — a value it was never allowed to
read." A `masked` value is *not* withheld: masking is a dashboard display property.
Kept all values non-`restricted`, since a `dp.st.` reads them either way but a
human's `dp.ct.` would not.

## 3. Storage model: verbatim names, and one shared namespace

**Direct.** "Default storage: Secret `{key}`, verbatim, in the config named by the
profile", and "SecretSpec's own project name is **unused**: the Doppler project in
the URI provides the namespace. **Two SecretSpec projects pointing at one
`doppler://project/config` therefore share a namespace.**"

This repo has exactly that shape: `nix` and `hermes` both resolve
`doppler://devenv/dev`. It is a faithful reproduction of the old state (both read
the same 1Password `dev` vault) and the key sets do not overlap. The cost is real
but bounded: a future hermes secret named `TS_AUTH_KEY` would silently read the root
manifest's value. Recorded in both manifests.

**Direct, and a trap for anyone who later adds a second profile.** "The config comes
from the **active** profile, which is not always the profile a secret is declared
in." Pinning `dev` in the URI makes the config constant regardless of which profile
is active, so `[profiles.default]` plus a pinned URI is immune to that. Dropping the
`/dev` from the URI would make `SECRETSPEC_PROFILE=default` demand a Doppler config
named `default`, which does not exist.

## 4. Constraints that changed the manifests, not just the URI

* **Direct — `field` cannot survive.** "Doppler secrets are single values with no
  sub-components, so `field`, `section`, `vault` and `version` are rejected rather
  than ignored." Every pre-cutover `ref = { item, field }` therefore had to go. The
  migration staged them as `refs = { op = { item, field } }` — provider-scoped,
  0.19+ — because "An entry may name an import-only source alias that is absent from
  the secret's ordinary `providers` route." That is the whole staging mechanism, and
  it is gone again now that the values are in Doppler.
* **Direct — a value containing `${` is refused on write**, because Doppler resolves
  `${OTHER_SECRET}` on read: "a value *containing* `${` cannot survive being written
  and read back". **Measured** for all four values this repo actually has
  (`TS_AUTH_KEY`, `GH_TOKEN`, `LONGCAT`, `OPENCODE_GO_PROVIDER`): none contains a
  reference, so nothing was refused. Hashes and lengths recorded in the migration
  transcript, values never printed.
* **Direct — name alphabets.** Secret names `^[A-Z_][A-Z0-9_]*$`, config and project
  names `^[a-z0-9_-]+$`. **Measured:** every declared key already fits; no rename was
  needed.
* **Direct — Doppler's reserved names** (`DOPPLER_PROJECT`, `DOPPLER_CONFIG`,
  `DOPPLER_ENVIRONMENT`) are filtered from reads and discovery, and declaring one is
  refused before any prompt. **Measured:** `doppler secrets get --only-names` shows
  all three in `devenv/dev` alongside a `PARALLEL_API_KEY` no manifest declares —
  which is fine: "A batch read asks Doppler only for the secrets your manifest
  declares."
* **Direct — reason forwarding is a provider capability.** The docs name Proton Pass,
  not Doppler. `require_reason = true` is still enforced and still recorded, but in
  **SecretSpec's own log** (`~/.local/state/secretspec/audit.log`, **measured** 641
  lines, `secretspec audit` to read). **Measured:** the entries now carry
  `"provider":"doppler://devenv/dev"` and the reason string. Doppler's own
  `doppler activity` will show that the config was read, by which token, and never
  why. This is the one place ADR 0013 pays a real cost against ADR 0007's wording.
* **Direct — the URI is sealed.** "Query parameters, fragments, user information and
  ports are rejected rather than ignored, so neither `doppler://myapp?config=prd` nor
  `doppler://myapp#prd` (a typo of `/` as `#`) can silently leave the profile naming
  the config and read a different Doppler environment."

## 5. Migration mechanics, measured

`secretspec import <FROM_PROVIDER>` — "**secrets will be imported to the default
provider**". With `[defaults] providers = ["dev"]` (a 0.21 section) as the
destination:

```console
✓ GH_TOKEN … (→ doppler)
✓ TS_AUTH_KEY … (→ doppler)
Summary: 2 imported, 0 already exists, 0 not found in source
```

and for hermes, `Summary: 2 imported, 0 already exists, 4 not found in source` —
those four (`GLM_API_KEY`, `ANTHROPIC_API_KEY`, `COMMANDCODE_API_KEY`,
`TAVILY_API_KEY`) had no 1Password item either, so the import re-measured the
manifest's own "declare it anyway, `required = false`" gap instead of masking it.
**No `--delete-source`:** the `dev` vault still holds the SSH key,
`CLOUDFLARE_API_TOKEN` and `NETCUP_CONSOLE`, none of which is a SecretSpec secret.

**A verification gotcha worth writing down.** `op read` emits a trailing newline and
`secretspec get` does not, so `… | sha256sum` on each side reports a MISMATCH for
identical values. Capture both through `$( )` and hash with `printf '%s'`. That first
false alarm is visible in the transcript: the "Doppler" hashes matched the
earlier `op`-side hashes exactly.

**Render path unchanged, measured.** `secretspec export --format dotenv` from the
Doppler provider emits exactly the two keys that have values, under their declared
names, and each hashed identically to the 1Password source
(`8a5f2c6821e7`, `011de05d3cac`).

## 6. What deliberately stays 1Password

Not in scope, and not moved: the `dev`-vault SSH signing key, `CLOUDFLARE_API_TOKEN`
(read directly by `modules/ingress.nix`), `NETCUP_CONSOLE`, and hermes' own
`secrets.onepassword` source in `hermes/modules/settings.nix`. That is why
`allow_unfree` and `pkgs._1password-cli` survive in the **shell** layer while the
package leaves the **machine** layer: `hosts/netcup/self-deploy.nix` carried it for
one stated reason — the provider shells out to `op` — and a REST provider removes the
premise, not just the preference. The ingress script interpolates
`${pkgs._1password-cli}/bin/op` into its own derivation, so it never depended on the
system package; **Measured:** the tokenless `devenv test` is green after the removal
(ADR 0010's claim, re-proved).

## 7. Unknown / open

* **The `dp.ct.` token printed itself into a research transcript** when
  `doppler configure debug` was run. It is `contabo`-scoped and created 2026-09-16.
  Rotation is a dashboard action and is **not done** as of this report. Treat it as
  exposed.
* **Whether `devenv machines install`'s bootstrap still works is unverified**, and
  cannot be verified without re-imaging netcup: `install.secrets` reads the same
  resolved value `secretspec get` does, which is the last line of defence rather than
  a proof. The host-side deploy is also where the `doppler` package added to
  `hosts/netcup/cli.nix` first gets exercised.
* **Nothing in the deployment puts a provider token on the host.** `install.secrets`
  delivers `TS_AUTH_KEY` to `/var/lib/tailscale/authkey` and nothing else, so
  `~/.config/doppler-token` is placed by an operator's hand — exactly as the `op`
  file beside it was. **Measured on the live host 2026-09-30:**
  `~/.config/doppler-token` absent; `~/.config/op-sa-token` `-rw------- hbohlen`, 857
  bytes. So the host-side loop's `secretspec run -- git push` step (README) fails
  there until the file is written, and that step is the only SecretSpec use the loop
  performs on the host.
* **The host already clears the version floor, from a different nixpkgs than this
  workstation's. Measured on the live host 2026-09-30:** `~/.nix-profile/bin/secretspec
  --version` → `secretspec 0.21.0`, `devenv 2.4.0`. The floor is 0.21+, so the host can
  speak Doppler; §1's "nixpkgs is 0.20.0" is a statement about the *locked rolling*
  input and this workstation's channel, not about the host's, which runs 26.11pre.
  `doppler` itself was absent (`command -v` finds nothing) — the package added to
  `hosts/netcup/cli.nix` is not deployed yet, and per §6 nothing needs it to be.
  `op` is at `/run/current-system/sw/bin/op`, i.e. still a system package until the
  `self-deploy.nix` drop is deployed.
* **Free-plan headroom, Direct from [platform limits](https://docs.doppler.com/docs/platform-limits):**
  10 projects, 50 service tokens, 4 environments per project, 1200 secrets per config,
  50 KiB per value, activity-log retention **3 days**, 120 secret reads/min per token.
* **The local audit log is not a permanent record either.** Direct from
  [concepts/audit](https://secretspec.dev/concepts/audit/index.md): it "is capped at
  1 MiB by default. When it reaches the cap it is truncated and started fresh", which
  the docs call "a size-bounded recent record rather than a complete, permanent
  history". **Measured:** 641 lines now, so the cap is not yet reached at this rate.
  So Doppler's three days is a downgrade on the *provider's* side, not a change of
  kind: neither log is a compliance archive, and the two are bounded differently —
  one by wall-clock, one by bytes. If the ordering of a resolution against a
  Doppler-side event ever matters past three days, forward the log before it rolls.
* **Unknown:** whether Doppler has any mechanism to attach a client-supplied reason
  to a secret *read*. Searched the activity-log event schema and the access-logs page;
  `reason` fields exist only on destructive admin actions.
