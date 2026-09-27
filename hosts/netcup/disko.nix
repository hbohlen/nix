# hosts/netcup/disko.nix — the boot disk layout for the netcup VPS.
#
# Two partitions, one filesystem type, four subvolumes. Deliberately not the
# previous build's nine-subvolume set: those were named for workloads that do
# not exist yet (@wiki, @projects, @agent-workspaces, @podman, @snapshots), and
# a subvolume nobody writes to is a mount option nobody has tested.
#
# WHY BTRFS AT ALL — the point is that subvolumes need no partition-table
# boundary decided at install time. Growing this host later is `btrfs
# subvolume create`, not a reinstall. That property is the whole reason to pay
# btrfs's complexity here, and it is why nothing below reserves unallocated
# space (no VM-based mechanism is possible on this host: no nested
# virtualization, measured — no /dev/kvm, no vmx/svm).
#
# NOT DECIDED HERE: swap (none this milestone) and encryption (none this
# milestone). Both are absent by omission rather than by choice, and the change
# records them as such.
{
  disko.devices = {
    disk.main = {
      # The target presents exactly one disk, a 1 TiB virtio device, as
      # /dev/vda. The install pre-flight verifies that on the target before
      # anything writes, because disko itself partitions without prompting and
      # has no dry run.
      device = "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              # Mounted at /boot, which host/default.nix's bootloader
              # efiSysMountPoint must equal (asserted there). umask=0077 keeps
              # the ESP root-only: systemd-boot needs root anyway, and nothing
              # else has business reading the bootloader's directory.
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            # 100% of what is left — see the header.
            size = "100%";
            content = {
              type = "btrfs";
              subvolumes = {
                "@" = {
                  mountpoint = "/";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "@nix" = {
                  # The store is reproducible, so it is the one subvolume a
                  # future snapshot policy should skip.
                  mountpoint = "/nix";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "@var" = {
                  # Churn lives here — logs, state, caches. Same reason to keep
                  # it separate from / from the first install rather than
                  # retrofitting it later, which is not possible without a
                  # migration.
                  mountpoint = "/var";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
