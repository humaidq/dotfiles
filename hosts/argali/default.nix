{
  pkgs,
  vars,
  config,
  self,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
  ];
  networking.hostName = "argali";

  sifr = {
    security.harden = false;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
    homelab = {
      adguard.enable = true;
      web-server.enable = true;
      lldap.enable = true;
      kavita.enable = true;
      mealie.enable = true;
      audiobookshelf.enable = true;
      jellyseerr.enable = true;
    };
    profiles.base = true;
    profiles.basePlus = true;
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";

  #boot.kernelPackages = pkgs.linuxPackages_rpi4;
  hardware.enableRedistributableFirmware = true;
  networking.networkmanager.enable = false;

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  networking.wireless = {
    enable = true;
    environmentFile = config.sops.secrets.wifi-2g.path;
    networks = {
      "@ssid@" = {
        psk = "@pass@";
      };
    };
  };

  boot.initrd.kernelModules = ["sun4i-drm"];
  boot.kernelPackages = pkgs.linuxPackages_latest;

  services.openssh.enable = true;
  networking.firewall.enable = false;

  #documentation.enable = lib.mkForce false;
  #documentation.nixos.enable = lib.mkForce false;
  #security.polkit.enable = lib.mkForce false;
  #security.rtkit.enable = lib.mkForce false;
  #security.apparmor.enable = lib.mkForce false;

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
  };
}
