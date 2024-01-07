{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [];

  boot.initrd.availableKernelModules = ["ahci" "xhci_pci" "nvme" "usbhid" "sr_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = [];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/87c46ad8-7ad8-42b8-9e5f-53f823524a0b";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/EEAC-61AD";
    fsType = "vfat";
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/7fbb6317-dfd6-4a3b-bf9e-a6fb7d0e05a4";}
  ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
