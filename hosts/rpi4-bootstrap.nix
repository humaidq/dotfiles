{
  pkgs,
  vars,
  self,
  inputs,
  ...
}: {
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    self.nixosModules.sifrOS
  ];
  networking.hostName = "sifrOS-rpi";
  nixpkgs.hostPlatform = "aarch64-linux";

  sifr = {
    security.harden = false;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
    profiles.base = true;
    profiles.basePlus = true;
  };

  system.stateVersion = "24.05";

  #boot.kernelPackages = pkgs.linuxPackages_rpi4;
  #hardware.enableRedistributableFirmware = true;
  networking.networkmanager.enable = false;

  #boot.loader.grub.enable = false;
  #boot.loader.generic-extlinux-compatible.enable = true;

  networking.wireless = {
    enable = true;
    networks = {
      "WIFI" = {
        psk = "psk";
      };
    };
  };

  environment.systemPackages = with pkgs; [
    libraspberrypi
    raspberrypi-eeprom
  ];
  boot.initrd.kernelModules = ["sun4i-drm"];

  services.openssh.enable = true;
  networking.firewall.enable = false;

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
  };
}
