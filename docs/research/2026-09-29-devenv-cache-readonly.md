# Diagnosis: `devenv info` fails with "Read-only file system" on `~/.cache/nix/fetcher-locks/`

**Date:** 2026-09-29
**Reporter:** the hermes-config effort (ticket 05)
**Symptom:** adding a new devenv input fails. `devenv info` (or any command that touches the lock) errors:

```
error: opening lock file ".../<hash>.lock": Read-only file system
```

## Verified repro

```sh
mkdir -p /tmp/devenv-repro && cd /tmp/devenv-repro
cat > devenv.yaml <<'EOF'
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
allow_unfree: true
shell: nu
require_version: true
EOF
cat > devenv.nix <<'EOF'
{ ... }: { }
EOF
~/nix/bin/devenv info  # fails: "Read-only file system"
```

Affected commands (any that evaluate a Nix expression that hits a new input):

- `devenv info`
- `devenv eval`
- `devenv shell` (intermittently — works if all inputs already have locks)
- `devenv machines info`
- `devenv build` for outputs that need a new lock

Existing projects (`~/nix/` with its current set of inputs) keep working because
their lock files exist. **Adding ANY new input anywhere on this workstation
fails.**

## Root cause

The Nix fetcher stores its lock files at `$HOME/.cache/nix/fetcher-locks/`
when `use-xdg-base-directories = false` (Determinate Nix default).

```
$ nix show-config | grep use-xdg-base
use-xdg-base-directories = false
```

The path `$HOME/.cache` resolves to `/home/hbohlen/.cache/` on this host,
which is on a btrfs subvolume mounted **read-only**:

```
$ findmnt -T /home/hbohlen/.cache/nix/fetcher-locks
TARGET SOURCE         FSTYPE OPTIONS
/      /dev/sda3      btrfs  ro,nosuid,nodev,...
$ findmnt -T /home/hbohlen/nix
TARGET             SOURCE                       FSTYPE OPTIONS
/home/hbohlen/nix  /dev/sda3[/home/hbohlen/nix]  btrfs  rw,nosuid,nodev,...
```

The repo lives on the rw mount; the cache lives on the ro mount. Existing
locks survive (they were created when the cache was rw); new locks cannot be
created.

`touch ~/.cache/nix/fetcher-locks/test.lock` → "Read-only file system".
Confirmed independently of devenv.

## Workaround (verified, 2026-09-29)

**`NIX_CACHE_HOME`** (per Nix 2.34 docs) overrides the cache directory
location regardless of `use-xdg-base-directories`. Set it before any
devenv/nix invocation:

```sh
export NIX_CACHE_HOME=/home/hbohlen/nix/.cache/nix
```

Verified: `devenv info` with `hermes-agent` + `home-manager` inputs
succeeds in `/tmp/devenv-test4` with this override, exits 0.

The `NIX_CACHE_HOME` value must be the FULL path including `/nix` at
the end (Nix appends `/fetcher-locks/` etc. internally). Tested:

- `NIX_CACHE_HOME=/home/hbohlen/nix/.cache/nix` → ✅ works
- `NIX_CACHE_HOME=/home/hbohlen/nix/.cache` → ❌ fails (different layout)

For the hermes effort specifically, the `bin/devenv` wrapper script at
`~/nix/bin/devenv` needs to set this before exec'ing the toolchain. The
patch is one line in the wrapper:

```sh
NIX_CACHE_HOME=/home/hbohlen/nix/.cache/nix exec "$exe" "$@"
```

Alternatively, set `NIX_CACHE_HOME` globally in `~/.zshrc` (works for all
devenv invocations, but affects every Nix command on the workstation —
broader scope).

**The `XDG_CACHE_HOME` approach was a red herring.** Determinate Nix
hard-codes `$HOME/.cache/nix` regardless of `XDG_CACHE_HOME` when
`use-xdg-base-directories = false`. The NIX_CACHE_HOME override is the
documented escape.

The symlink approach (`~/.cache/nix -> ~/nix/.cache/nix`) is blocked by
the ro filesystem — the existing non-empty `~/.cache/nix` directory
cannot be replaced with a symlink on a read-only mount.

## Why this regressed (educated guess, not verified)

Lock files were created as recently as 2026-09-29 22:06 (today, earlier in
the session). The regression happened sometime between then and the hermes
work at ~22:59. Possible triggers:

- A `nix-store-remount-rw.service` execution that remounted `/nix/store`
  rw AND cascaded the rest of the root subvolume to ro by accident
  (per the README, this service exists and remounts `/nix/store`).
- A NixOS rebuild that changed the mount table.
- An unrelated `mount -o remount` operation.

To verify, check `journalctl` for `nix-store-remount-rw` entries around
22:06-22:30.

## Real fixes (in order of effort)

1. **Symlink** `~/.cache/nix → ~/nix/.cache/nix`. No global env change.
   Works because the rw subvolume is under `~/nix/`. Operator-confirmable.
   This is the **immediate fix**.
2. **Set `XDG_CACHE_HOME` in login shell.** Same effect as the symlink,
   broader scope (covers any tool that respects XDG).
3. **Remount `/` rw** at boot, or adjust `nix-store-remount-rw.service` so
   it doesn't cascade the root subvolume to ro. Host-level; needs the
   netcup deploy.
4. **Configure Nix to use a custom `state-dir`** via `nix.settings` in
   `/etc/nix/nix.conf` (NixOS) or `~/.config/nix/nix.conf` (per-user):
   `experimental-features = nix-command` + state-dir option. Requires
   Nix 2.36+ experimental.

For the hermes effort, option 1 (symlink) is the unblocker.

## What was rolled back

The sub-project attempt at `~/nix/hermes/{devenv.yaml,devenv.nix}` was
rolled back to capture this finding cleanly. Re-attempt ticket 05 after
option 1 (or 2) is in place.

## Follow-up (2026-09-30)

**RESOLVED WITHOUT THE WORKAROUND.** At 23:26 the root subvolume came back
rw — `findmnt -T ~/.cache/nix/fetcher-locks` now reports `ro` gone from the
options, and the ticket-05 repro runs green with NO `NIX_CACHE_HOME` set.
The remount window was brief (~22:59–23:26), consistent with the
`nix-store-remount-rw.service` cascade hypothesis above. `bin/devenv` is
therefore NOT patched: a host-wide env change for a constraint that no
longer holds fails its own portability logic. If it returns, this doc's
workaround (`NIX_CACHE_HOME=/home/hbohlen/nix/.cache/nix`, full path incl.
`/nix`) is verified and one line from the wrapper.
