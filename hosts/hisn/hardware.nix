# Deliberately thin, unlike the generated hardware.nix on its siblings. The
# filesystems and their devices are declared in disk.nix and produced by disko,
# so repeating them here would create a second place to disagree with the disk.
#
# The virtio module set comes from the qemu-guest profile rather than a
# hand-listed array. srvos's hardware-vultr-vm did the same for the two hosts
# this replaces, but that module is not reused: it also configures cloud-init
# for the Vultr datasource, and this host is neither on Vultr nor running
# cloud-init.
{ modulesPath, lib, ... }:
{
  imports = [
    "${modulesPath}/installer/scan/not-detected.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Static, because the provider hands out no DHCP: netplan on the stock image
  # had dhcp4 false and a fixed address. A host that falls back to the NixOS
  # default of DHCP here comes up with no route to anywhere and, with ssh not
  # opened to the WAN, no way to be told otherwise.
  networking = {
    useDHCP = false;
    interfaces.enp1s0.ipv4.addresses = [
      {
        address = "45.59.120.67";
        prefixLength = 24;
      }
    ];
    defaultGateway = {
      address = "45.59.120.1";
      interface = "enp1s0";
    };
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  # Pins the name the static address above is attached to. One NIC on a fixed
  # PCI slot makes enp1s0 stable in practice, but the failure mode if a kernel
  # or systemd update ever disagrees is a machine with no address and no way in,
  # so it is matched on its MAC instead of assumed.
  systemd.network.links."10-wan" = {
    matchConfig.MACAddress = "52:54:00:24:98:d8";
    linkConfig.Name = "enp1s0";
  };
}
