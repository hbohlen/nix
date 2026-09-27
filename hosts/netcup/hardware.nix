# hosts/netcup/hardware.nix — the hardware facts disko cannot derive.
#
# Almost empty ON PURPOSE. disko generates every `fileSystems` entry from
# ./disko.nix, so there is no UUID table to transcribe and no generated
# hardware report to keep in sync (the Machine sets `hardware.facter = null`).
# What disko cannot know is which storage drivers the initrd must carry to see
# a virtio disk at all.
#
# Measured history worth keeping: the previous build's BIOS-era deployment timed
# out waiting for /dev/vda partitions because the initrd had no VirtIO modules.
# The qemu-guest profile supplies them, and the explicit list below is the
# belt-and-braces that costs nothing.
{
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sr_mod"
  ];
}
