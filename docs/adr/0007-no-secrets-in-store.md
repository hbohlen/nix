# 0007 — Secrets enter the store nowhere; secretspec is on the machines path by exception

Secret values must never become Nix store content: the tailscale auth key is
declared as a `install.secrets` STRING (a path literal would copy it into the
world-readable store), and `OP_SERVICE_ACCOUNT_TOKEN` is read at shell start
and never becomes a Nix `env` entry. The counterweight, accepted: putting
`TS_AUTH_KEY` on the `machines` path through `secretspec.toml` means every
`devenv machines` command — read-only `info` included — resolves the whole
secretspec profile. That coupling is the price of enrollment being a property
of the machine rather than of an operator's session. Rejected alternative:
target-side 1Password resolution, which would need a service-account token on a
throwaway kexec'd installer.
