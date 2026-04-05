{
  inputs,
  modulesPath,
  vars,
  self,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.desktop
    self.nixosModules.sifrOS.installer
    self.nixosModules.sifrOS.security
  ];
  networking.hostName = "sifrOS-installer";
  networking.hostId = "00000000";
  nixpkgs.hostPlatform = "x86_64-linux";

  sifr = {
    desktop.sway.enable = true;
    installer.enable = true;
    security.harden = false;
  };

  services.greetd.settings.initial_session = {
    command = lib.getExe pkgs.sway;
    inherit (vars) user;
  };

  system.stateVersion = "25.11";

  boot.supportedFilesystems = {
    zfs = lib.mkForce true;
  };
  hardware.enableRedistributableFirmware = true;
  services.openssh.enable = true;
  networking.firewall.enable = false;
  services.getty.autologinUser = vars.user;
  security.sudo-rs.wheelNeedsPassword = false;
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = [ inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.default ];

  users.users.${vars.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };
}
