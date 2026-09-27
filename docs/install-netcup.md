# Install netcup as a devenv Machine

The one procedure this repository exists for right now: take a freshly imaged
netcup VPS and end up with a booting NixOS host reachable over SSH.

Everything here is run from the repository root, and every `devenv` is
`./bin/devenv` — the pinned 2.4.0 toolchain. Bare `devenv` on this workstation
is 2.2.2 and has no `machines` subcommand.

## What the target is

| Fact | Value | How it was measured |
|---|---|---|
| Public IPv4 | `152.53.92.126` | on the target: `ip -4 -br addr show eth0` |
| Boot disk | `/dev/vda`, 1 TiB, virtio | `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS` |
| Firmware | UEFI, enabled in the netcup panel | provider panel |
| Throwaway OS | Ubuntu 22.04.5 LTS, hostname `nc`, kernel 5.15.0-194-generic | `hostnamectl`, `uname -r` |
| Host identity | ed25519 `SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ` | `ssh-keygen -lf` on the derived public key |

The identity is the 1Password `dev` vault item `SSH Key`. It is **not** this
workstation's own `~/.ssh/id_ed25519` (`SHA256:DnpZNFST…`) — a different key.
Only the fingerprint is recorded here; the private half stays in the vault and
is materialized per use.

## Step 0 — the workstation's SSH configuration is broken

`~/.ssh/config` includes `deploy/ssh-config.netcup` from the *previous*
repository, whose line 13 sets
`IdentityAgent ${XDG_RUNTIME_DIR}/ssh-agent.socket`. `sshd`'s client does not
expand that variable in non-interactive environments, so **every** `ssh`
invocation aborts with

```
Invalid environment expansion ${XDG_RUNTIME_DIR}/ssh-agent.socket.
... terminating, 1 bad configuration options
```

until it is fixed. Every command below therefore passes `-F /dev/null` and
pins the identity explicitly. Do not "just try ssh" and conclude the host is
down.

## Step 1 — materialize the identity

```bash
OP="$(cat ~/.config/op-sa-token)"        # service-account token, 0600
KEY=~/.ssh/id_ed25519-op-dev
(umask 077; printf '{{ op://dev/SSH Key/private key }}' > /tmp/tpl)
op inject -i /tmp/tpl -o "$KEY" --file-mode 0600 -f
rm -f /tmp/tpl
printf '\n' >> "$KEY"                     # REQUIRED — see below
chmod 600 "$KEY"
ssh-keygen -y -f "$KEY" > /tmp/k.pub && ssh-keygen -lf /tmp/k.pub; rm -f /tmp/k.pub
```

Expected: `256 SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ`.

The appended newline is not cosmetic. `op inject` writes the value
byte-exact, and the vault's value ends at `-----END OPENSSH PRIVATE KEY-----`
with no trailing newline: 398 bytes, and `ssh-keygen` refuses it as
`invalid format`. Any script that materializes this key must add it.

## Step 2 — clear the stale host key

A re-image always replaces the host key, so strict checking refuses the first
connection:

```bash
ssh-keygen -R 152.53.92.126
```

Expected: `known_hosts updated`, with the previous contents kept at
`known_hosts.old`. This is a re-imaged host, not a host-key-swap attack —
confirm that with the operator before doing it on a host you did not just
re-image.

## Step 3 — verify root SSH, and prove *which* key was accepted

```bash
ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519-op-dev \
    root@152.53.92.126 'hostname; head -2 /etc/os-release; uname -r; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS'
```

Then confirm server-side rather than assuming:

```bash
ssh ... root@152.53.92.126 'ssh-keygen -lf <(cut -d" " -f1-2 /root/.ssh/authorized_keys); journalctl -u ssh -n 20 | grep "Accepted publickey"'
```

Expected: `/root/.ssh/authorized_keys` holds exactly one key, and sshd logged
`Accepted publickey for root … ED25519 SHA256:HvoLYt+…`. **If the logged
fingerprint is not that one, stop** — the install would trust a key the
operator does not hold.

This is also the gate that proves the deployment target is the intended host:
the public address, plus `hostname` and the SSH host key, together.

## Step 4 — the local build gate (before anything writes)

```bash
./bin/devenv build machines.netcup
```

`install` partitions and formats without prompting and has no dry run, so a
closure that will not build must be discovered while the target is still
disposable. Expected: exit zero and five realised store paths — the NixOS
system, the deployer, and the disko layout/format/mount scripts. Measured
2026-09-27: 97.9 s, everything substituted from `cache.nixos.org`.

## Step 5 — the install (irreversible)

```bash
./bin/devenv machines install netcup
```

This kexecs the target into a NixOS installer, partitions `/dev/vda` via disko,
copies the closure, installs systemd-boot, and reboots. If it is interrupted,
inspect the phase it reports and resume with `--phases` rather than restarting
blindly.

No secret provider is involved: this repository has no `secretspec.toml`, and
`install.secrets` / `install.extraFiles` are unused, so the run needs no vault
session and no pre-pinned host keys.

## Step 6 — post-install evidence

```bash
ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes \
    -i ~/.ssh/id_ed25519-op-dev root@152.53.92.126 '
      nixos-version; bootctl status | head -5; swapon --show;
      findmnt -no SOURCE,FSTYPE,OPTIONS / /home /nix /var'
```

Expected: `nixos-version` reports the installed release and not the installer's
environment; `/`, `/home`, `/nix`, `/var` are btrfs subvolumes `@`, `@home`,
`@nix`, `@var` with `compress=zstd,noatime`; `swapon --show` prints nothing;
`bootctl status` reports the booted entry. Then reboot once and confirm the
host returns to SSH with no console interaction — an unattended UEFI boot is
the whole point of the layout.

## Recovery

There is no in-place rollback for this milestone, and none is needed. If the
install fails, the host is re-imaged with a fresh OS with root SSH open, the
stale host key is cleared again, and the procedure restarts at step 3. No
state from the failed attempt is required on the target — that is why the
throwaway OS is part of the design rather than an inconvenience.

The out-of-band path, if the host does not come back at all, is the netcup
server control panel (`https://www.servercontrolpanel.de`, credentials in the
1Password `dev` vault as `NETCUP_CONSOLE`, which also carries the TOTP).

## What this procedure deliberately does not do

No tailnet enrollment, no secret provisioning on the host, no hardening beyond
key-only SSH, no firewall policy of our own (the nixpkgs defaults give a
deny-by-default firewall with sshd's port opened). Each of those is a separate
change that adds exactly one moving part.
