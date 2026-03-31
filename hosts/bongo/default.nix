{
  self,
  vars,
  lib,
  inputs,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    inputs.disko.nixosModules.disko
    #inputs.lanzaboote.nixosModules.lanzaboote
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "bongo";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    openFirewall = false;
  };

  users.users."${vars.user}" = {
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
  };

  #sops.secrets."nebula/crt" = {
  #  sopsFile = ../../secrets/bongo.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};
  #sops.secrets."nebula/key" = {
  #  sopsFile = ../../secrets/bongo.yaml;
  #  owner = "nebula-sifr0";
  #  mode = "600";
  #};

  sops.secrets."etisalat/pppd-config" = {
    sopsFile = ../../secrets/bongo.yaml;
  };

  sops.secrets."dnsmasq/dhcp-hosts" = {
    sopsFile = ../../secrets/bongo.yaml;
    owner = "dnsmasq";
    group = "dnsmasq";
    mode = "0400";
  };

  sifr = {
    #profiles.basePlus = true;
    profiles.server = true;
    autoupgrade.enable = true;
    o11y.client.enable = true;

    router = {
      enable = true;
      pppdConfig = config.sops.secrets."etisalat/pppd-config".path;
    };

    net = {
      sifr0 = false;
      cacheOverPublic = true;
      node-crt = config.sops.secrets."nebula/crt".path;
      node-key = config.sops.secrets."nebula/key".path;
    };

    persist = {
      enable = true;
      btrfs.enable = true;
    };
  };

  services.dnsmasq.settings.dhcp-hostsfile = config.sops.secrets."dnsmasq/dhcp-hosts".path;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.11";
}
