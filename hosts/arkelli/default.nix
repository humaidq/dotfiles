{
  config,
  self,
  inputs,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    (import ./hardware.nix)
  ];

  networking = {
    hostName = "arkelli";

    # TODO properly configure firewall rules
    firewall.enable = false;

    # TODO define connections as nm files
    networkmanager.enable = false;
    wireless = {
      enable = true;
      environmentFile = config.sops.secrets.wifi-2g.path;
      networks = {
        "@ssid@" = {
          psk = "@pass@";
        };
      };
    };
  };

  sifr = {
    security.harden = false;
    tailscale = {
      enable = true;
      ssh = true;
    };
    homelab = {
      lldap.enable = true;
      kavita.enable = true;
      mealie.enable = true;
      audiobookshelf.enable = true;
      jellyseerr.enable = true;
      nas-media.enable = false;
      deluge.enable = true;
      radarr.enable = true;
      prowlarr.enable = true;
    };

    profiles.base = true;
    profiles.basePlus = true;
  };

  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "24.05";

  services.openssh.enable = true;
}
