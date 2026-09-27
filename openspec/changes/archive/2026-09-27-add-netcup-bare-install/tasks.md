## 1. Toolchain and inputs

- [x] 1.1 Obtain devenv 2.4 or newer, substituting from the devenv cache rather
      than compiling: `nix build 'github:cachix/devenv/v2.4.0#devenv' --no-link
      --print-out-paths --option extra-substituters https://devenv.cachix.org
      --option extra-trusted-public-keys
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="`.
      Verify: the binary reports `--version` ≥ 2.4.0 and `devenv machines --help`
      lists `install`.
- [x] 1.2 Write `devenv.yaml` declaring `inputs.nixpkgs`
      (`github:cachix/devenv-nixpkgs/rolling`) and `inputs.disko`
      (`github:nix-community/disko`) with the **nested** follow form. Verify:
      `devenv update disko` produces a real `disko` node in `devenv.lock` and
      `root.inputs.disko` is the string `"disko"` — the flat `follows:` form
      silently locks the input as an alias of nixpkgs.
- [x] 1.3 Bump `devenv.lock`'s `devenv` input to the 2.4 revision in the same
      pass. Verify: the lock's `devenv` node revision matches the binary's build
      revision, and `devenv eval env.GREET` still evaluates.

## 2. Machine declaration and minimal host configuration

- [x] 2.1 Write `devenv.nix` with `machines.netcup`: `system =
      "x86_64-linux"`, `target.host` set to the target's public address,
      `hardware.facter = null`, and a `nixos` module importing the host files.
- [x] 2.2 Write `hosts/netcup/hardware.nix` carrying only the kernel-side facts a
      QEMU/KVM guest needs (VirtIO initrd modules). Verify: no
      `nixos-facter-modules` input is declared and evaluation still succeeds.
- [x] 2.3 Set `networking.hostName = "netcup"` and `system.stateVersion` to the
      release the Machine's own nixpkgs reports, read from the evaluated system
      name rather than from memory. Verify: `devenv eval
      machines.netcup.build.nixos` prints a `nixos-system-netcup-<release>`
      path whose `<release>` matches the `system.stateVersion` string.
- [x] 2.4 Declare the operator account (normal user, `wheel`, no usable
      password, passwordless sudo) and authorize the operator's ed25519 key for
      it. Verify: the key appears in the evaluated account's
      `openssh.authorizedKeys.keys` and `hashedPassword` is a lock marker.
- [x] 2.5 Configure sshd: enabled on port 22, password authentication disabled,
      and the operator key also authorized for `root`. Verify: the evaluated
      sshd settings show password authentication disabled, and root's authorized
      keys carry the same fingerprint.
- [x] 2.6 Configure UEFI boot: systemd-boot enabled with a bounded generation
      limit, `efiSysMountPoint = "/boot"`, `canTouchEfiVariables = false`.
- [x] 2.7 Verify the declaration end to end with no secret provider available:
      `devenv machines info` lists `netcup` with role `nixos`, and `devenv eval
      machines.netcup.build.nixos` succeeds, on a workstation with no vault
      session and no `secretspec.toml` in the repository.

## 3. Disk layout

- [x] 3.1 Write `hosts/netcup/disko.nix`: one GPT disk on `/dev/vda`, one 1 GiB
      `EF00` vfat partition mounted at `/boot` with `umask=0077`, one `100%`
      btrfs partition, subvolumes `@` → `/`, `@home` → `/home`, `@nix` → `/nix`,
      `@var` → `/var`, each with `compress=zstd` and `noatime`.
- [x] 3.2 Verify the layout by evaluation only: exactly one disk whose device is
      `/dev/vda`, exactly two partitions (sizes 1 GiB and 100%), the four
      subvolumes with the declared mountpoints and options, no swap device and
      no `swapDevices` entry, and no encryption layer.
- [x] 3.3 Verify the boot mount points agree: the ESP's mountpoint and the
      bootloader's `efiSysMountPoint` are both `/boot`.

## 4. Repository invariants (no host contact)

- [x] 4.1 Verify no competing host-definition surface exists: no `flake.nix`
      exporting `nixosConfigurations`, and no `lib/mkHost.nix`.
- [x] 4.2 Verify the install path carries no secret provider: no
      `secretspec.toml`, no `secretspec.enable` in `devenv.yaml`, and the 2.7
      checks pass with the vault client absent from `PATH`.
- [x] 4.3 Verify no module sets `nixpkgs.config`, which a Machine cannot accept
      because devenv creates the pkgs instance outside the module system.
- [x] 4.4 Verify no private key material is committed: a search for
      `PRIVATE KEY` across the repository returns nothing, and the only key
      material present is the operator public key.

## 5. Procedure documentation

- [x] 5.1 Write the install document: the preconditions and the commands that
      check them, the single install command, the post-install evidence
      commands, the recovery path, and the target's identity (public address,
      boot disk device path, key fingerprint).
- [x] 5.2 Verify the document names the key by fingerprint only and contains no
      credential value.

## 6. Pre-install gates (local build first, then the live target)

- [x] 6.1 Build the Machine's system LOCALLY before anything writes to the
      target: `./bin/devenv build machines.netcup`. Rationale: `install`
      partitions and formats without prompting and offers no dry run, so a
      closure that will not build must be discovered while the target is still
      disposable. Verify: the command exits zero and the evaluated system path
      is realised, not merely described.
- [x] 6.2 Materialize the host identity from the vault with `op inject` into a
      `0600` file, then append the trailing newline the injected value lacks
      (measured: the value is 398 bytes and `ssh-keygen` reports `invalid
      format` until a newline is added). Prove it with the derived public key
      (`ssh-keygen -y … | ssh-keygen -lf -`) matching
      `SHA256:HvoLYt+w9VdcQPwLsF72g9/BZRlwjIaNkHkhJuNHqIQ`. Never print the
      private key, and never place it in an environment variable.
- [x] 6.3 Clear the stale host key a re-image always leaves behind:
      `ssh-keygen -R <address>` the previous entries before first contact, then
      let the new host key be accepted and recorded.
- [x] 6.4 Confirm root SSH is open on the freshly imaged target, bypassing the
      workstation's ambient SSH configuration explicitly (an `-F /dev/null`
      style invocation with the identity pinned) so the broken
      `${XDG_RUNTIME_DIR}` `IdentityAgent` line cannot abort the connection, and
      confirm server-side which key was accepted (`journalctl -u ssh` reporting
      `Accepted publickey … SHA256:HvoLYt+…`) rather than assuming it.
- [x] 6.5 Verify the target's boot disk is presented as `/dev/vda` and record
      the output.
- [x] 6.6 Verify the target is the intended host — public IPv4, and a second
      identifying fact — and record it.
- [x] 6.7 Record all gate results. No partitioning command runs until every one
      of them is complete and green.

## 7. The install (irreversible)

- [x] 7.1 Run the single install command against the prepared target, with the
      recorded pre-flight output as the evidence that the run is against the
      intended host. Verify: the command completes and reboots the host.
- [x] 7.2 If the run is interrupted, inspect the reported phase and resume with
      `--phases` rather than restarting from the beginning blindly.

## 8. Post-install verification

- [x] 8.1 Verify key-only SSH login succeeds as the operator account over the
      target's public address.
- [x] 8.2 Verify root SSH succeeds with the same key, so later deploys have a
      path.
- [x] 8.3 Verify password authentication is refused for both accounts.
- [x] 8.4 Verify `nixos-version` reports the installed release and not the
      installer's environment.
- [x] 8.5 Verify `/`, `/home`, `/nix` and `/var` are btrfs subvolumes `@`,
      `@home`, `@nix`, `@var` mounted with `compress=zstd` and `noatime`, and
      that `swapon --show` is empty.
- [x] 8.6 Verify a clean reboot: reboot the host and confirm it returns to SSH
      with no console interaction, and that `bootctl status` reports the booted
      entry.

## 9. Validation and follow-up

- [x] 9.1 Run `openspec validate add-netcup-bare-install --strict` and confirm
      every requirement has a passing scenario result, with any boot-dependent
      scenario resolved by 8.x rather than assumed.
- [x] 9.2 Record the outcome against the open questions in `design.md`,
      especially the `system.stateVersion` release and whether the freshly
      imaged OS's EFI variables affected the first boot.
- [x] 9.3 Archive the change and scaffold the two follow-ups it deliberately
      excludes: closing root login (which must also decide what replaces the
      deploy path) and adding tailnet access.
      Done 2026-09-27: archived as `2026-09-27-add-netcup-bare-install` with its
      requirements promoted into `openspec/specs/`. The follow-ups are **not**
      scaffolded as changes yet — they are framed for discussion in
      `docs/handoff-followups.md`, because follow-up 1 needs one experiment
      (non-root `machines deploy`) before its spec can be written honestly.
- [x] 9.4 Commit the work in the colocated jj/Git repository, one described
      change per action.
