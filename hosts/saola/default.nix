{
  self,
  vars,
  lib,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "saola";
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      apps = true;
    };
    profiles = {
      basePlus = true;
    };
  };
  services.openssh.enable = true;
  networking.firewall.enable = false;

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";
}
