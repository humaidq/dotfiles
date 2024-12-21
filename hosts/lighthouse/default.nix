{
  self,
  vars,
  lib,
  config,
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

  # Nebula keys
  sops.secrets."lighthouse_crt" = {
    sopsFile = ../../secrets/lighthouse.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."lighthouse_key" = {
    sopsFile = ../../secrets/lighthouse.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

  sifr = {
    net = {
      sifr0 = true;
      isLighthouse = true;
      node-crt = config.sops.secrets."lighthouse_crt".path;
      node-key = config.sops.secrets."lighthouse_key".path;
    };
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
  system.stateVersion = "24.11";
}
