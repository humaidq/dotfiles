# A declared layout rather than the provider image's, which is the whole
# reason this host is installed with nixos-anywhere instead of converted in
# place. The stock Ubuntu cloud image ships a GPT with four partitions — root,
# a bios_grub, an ESP, and a separate /boot — and an in-place conversion
# inherits all of it: grub's core.img embeds a prefix pointing at whichever of
# those happened to be mounted when it ran, and nothing declares that the next
# rebuild has to agree. An attempt at exactly that left the machine at a
# blinking cursor with no bootloader output at all.
#
# BIOS boot, so an EF02 partition and no ESP: the firmware here reports no
# /sys/firmware/efi, and carrying an unused EFI system partition around is how
# the ambiguity above starts. Single ext4 root, matching the two hosts this
# replaces — there is no snapshot or rollback story on this machine that would
# pay for btrfs.
{
  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/vda";
        content = {
          type = "gpt";
          partitions = {
            # Holds grub's core.img. Required on GPT for i386-pc: without it
            # grub-install has nowhere to embed and either refuses or falls
            # back to block lists.
            boot = {
              size = "1M";
              type = "EF02";
            };
            swap = {
              size = "2G";
              content = {
                type = "swap";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
