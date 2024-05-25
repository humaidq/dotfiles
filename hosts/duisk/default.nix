{
  self,
  vars,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
  ];
  networking.name = "duisk";

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    extraGroups = ["caddy"];
  };
  services.tailscale.useRoutingFeatures = "both";

  sifr = {
    profiles.basePlus = true;
    caddy.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
