{
  self,
  ...
}:
{
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };

  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.personal.kids
    self.nixosModules.sifrOS.laptop
    self.nixosModules.sifrOS.desktop
    self.nixosModules.sifrOS.security
  ];
  networking.hostName = "serow-vm";
  boot.loader.grub.device = "nodev";

  # My configuration specific settings
  sifr = {
    personal.kids.enable = true;
    basePlus.enable = true;
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
