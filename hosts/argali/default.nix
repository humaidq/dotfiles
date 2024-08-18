{
  config,
  self,
  lib,
  inputs,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    (import ./hardware.nix)
  ];

  sifr = {
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
    homelab = {
      adguard.enable = true;
      web-server.enable = true;
    };
    profiles.server = true;

    # TODO re-enable
    security.harden = false;
  };

  topology.self.interfaces.end0.network = "home";
  networking = {
    hostName = "argali";

    # This device is a DHCP server
    useDHCP = lib.mkForce false;
    defaultGateway = "192.168.1.1";
    interfaces.end0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.250";
          prefixLength = 24;
        }
      ];
    };
    resolvconf.useLocalResolver = true;

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

  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "23.11";

  services.openssh.enable = true;
}
