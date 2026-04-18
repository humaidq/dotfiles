{
  modulesPath,
  self,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-base.nix")
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

  system.stateVersion = "25.11";
}
