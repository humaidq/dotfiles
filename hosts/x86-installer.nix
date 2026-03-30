{
  vars,
  self,
  lib,
  ...
}:
{
  imports = [ self.nixosModules.sifrOS ];
  networking.hostName = "sifrOS-installer";
  networking.hostId = "00000000";
  nixpkgs.hostPlatform = "x86_64-linux";

  sifr = {
    graphics.sway.enable = true;
    security.harden = false;
    profiles.base = true;
    profiles.basePlus = false;
    profiles.installer = true;
  };

  services.displayManager.autoLogin = {
    enable = true;
    inherit (vars) user;
  };
  services.displayManager.gdm.autoSuspend = false;

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

  users.users.${vars.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };
}
