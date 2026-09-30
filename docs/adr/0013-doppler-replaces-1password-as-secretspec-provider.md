# 0013 — Doppler is the SecretSpec provider; 1Password stays for what is not SecretSpec

Both `secretspec.toml` manifests resolve against `doppler://devenv/dev` with a
read-only `dp.st.` service token, replacing `onepassword+token://dev`. The
provider alias stays `dev`, so every `SECRETSPEC_PROVIDER=dev` string in the
runbooks and the deploy loop survives unchanged — only the URI moved. ADR 0007's
invariant is untouched and re-proved: no secret value ever becomes store content,
and resolution stays local rather than target-side. What ADR 0007 amends here is
its *wording*: `OP_SERVICE_ACCOUNT_TOKEN` was named as the credential at rest
because that was the only provider credential there was.

## Why

The Doppler provider talks REST: "reads and writes secrets in a Doppler project
over Doppler's REST API. No `doppler` CLI is required"
([providers/doppler](https://secretspec.dev/providers/doppler/)). The 1Password
provider is a wrapper around the `op` binary — measured by putting a sentinel
first on PATH and watching `machines info` invoke it
(`SHIM-SENTINEL: op was invoked with: vault list --format json`). So the host
carried `pkgs._1password-cli` in `environment.systemPackages` for one stated
reason, and a REST provider removes the premise, not just the preference.
`devenv machines install` kexec's a throwaway target: a provider that needs a
binary and a vault credential there was always the weaker half of the design.

Doppler also gives the layout this repo already has: one project, per-purpose
configs, verbatim declared names, no item/field addressing. The plan's `dp.sa.`
service-account token turned out to be unbuyable — Service Accounts are
paywalled on the free Developer plan — so the credential is a `dp.st.` service
token minted for the pinned `dev` config, which is what the URI names
([2026-09-30 research](../research/2026-09-30-secretspec-doppler-provider.md)).

## What it costs

- **A version floor.** The provider is 0.21+; `nixpkgs` (the locked
  `devenv-nixpkgs/rolling` and this host's `<nixpkgs>`) is still 0.20.0. The
  durable CLI is therefore cargo-installed at 0.21.1, matching the copy devenv
  2.4.0 links. An older `secretspec` on PATH does not fail loudly — it fails to
  know the URI scheme.
- **`${` is refused on write.** Doppler resolves `${VAR}` references, so a value
  containing it cannot be imported. Every migrated value was screened first.
- **Reason attribution moves.** `require_reason = true` is still enforced, but
  the reason lands in SecretSpec's own log, not the provider's: Proton Pass is
  the docs' example of a provider that receives it, Doppler is not. Both logs are
  bounded — Doppler's activity log is 3 days, SecretSpec's is capped at 1 MiB and
  truncates — so neither is a compliance archive.
- **One more outage domain.** A Doppler outage now blocks the `machines` path the
  way a 1Password outage did. `providers = ["dev", "op"]` was available and
  rejected: a fallback chain keeps the vault on the resolution path, which is the
  dependency this change removes.

## What deliberately stays 1Password

- The SSH identity at `target.sshOpts` (`~/.ssh/id_ed25519-op-dev`): materialized
  by `op` at the moment of use, never a SecretSpec secret.
- `CLOUDFLARE_API_TOKEN`, which `modules/ingress.nix` reads with `op read`
  straight from the vault. Adding it to the manifest would put it on every
  `devenv machines` path — the cost that manifest's header already resists.
- hermes's own `secrets.onepassword` source, so `hermes/devenv.yaml` keeps
  `allow_unfree: true` and the shell layer keeps `op` as a package.

## Consequences

- `hosts/netcup/self-deploy.nix` installs `pkgs.git` and no `op`. Safe because the
  ingress script interpolates `${pkgs._1password-cli}/bin/op` into its own
  derivation — a literal store path, not a PATH lookup — so dropping the system
  package breaks nothing. Measured: the tokenless `devenv test` is green after the
  removal, which is ADR 0010's claim, unamended and re-proved.
- **Two token files, one provider credential.** `~/.config/doppler-token` is the
  bootstrap for the SecretSpec path; `~/.config/op-sa-token` now only serves
  non-SecretSpec consumers. Neither may be declared as a SecretSpec secret: the
  credential is what the provider needs in order to resolve anything, including
  itself. That is D36's circularity argument, and it generalizes — it was never
  about 1Password.
- **One namespace, two manifests.** Both files point at the same config and
  SecretSpec's own project name is unused, so a new secret named `TS_AUTH_KEY` in
  `hermes/secretspec.toml` would silently read the root manifest's value. The key
  sets do not overlap today; the constraint is recorded in both headers.
- `pkgs.doppler` is on netcup through Home Manager (`hosts/netcup/cli.nix`) as
  operator convenience only, never as a precondition — and the CLI's own
  `doppler login` token is not what SecretSpec reads.
