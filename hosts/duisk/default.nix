{
  self,
  vars,
  lib,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.server
    (import ./hardware.nix)
    (import ./webserver.nix)
    (import ./blocky.nix)
  ];
  networking.hostName = "duisk";

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
    extraGroups = [ "caddy" ];
  };

  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/duisk.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/duisk.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

  sifr = {
    autoupgrade.enable = true;
    basePlus.enable = true;
    personal = {
      net = {
        sifr0 = true;
        cacheOverPublic = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
      };
      o11y.client.enable = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";
}
