{
  config,
  self,
  inputs,
  ...
}:
{
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
    profiles.server = true;
    o11y.client.enable = true;

    # TODO re-enable
    security.harden = false;
  };

  topology.self.interfaces.end0.network = "home";
  networking = {
    hostName = "argali";

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
