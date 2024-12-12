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
  ];
  networking.hostName = "lighthouse";

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };
  services.tailscale.useRoutingFeatures = "both";

  sifr = {
    profiles.basePlus = true;
    profiles.server = true;
    #autoupgrade.enable = true;
    o11y.client.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
