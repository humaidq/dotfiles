{
  vars,
  self,
  lib,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
  ];
  networking.hostName = "sifrOS-installer";
  nixpkgs.hostPlatform = "x86_64-linux";

  sifr = {
    graphics.gnome.enable = true;
    security.harden = false;
    profiles.base = true;
    profiles.basePlus = false;
  };

  services.displayManager.autoLogin = {
    enable = true;
    inherit (vars) user;
  };
  services.xserver.displayManager.gdm.autoSuspend = false;

  system.stateVersion = "24.05";

  hardware.enableRedistributableFirmware = true;
  services.openssh.enable = true;
  networking.firewall.enable = false;
  services.getty.autologinUser = vars.user;

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };
}
