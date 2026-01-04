{ lib, config, ... }:
{
  imports = [
    ./tailscale.nix
    ./nebula.nix
    ./time.nix
    ./dns.nix
    ./rclone.nix
  ];
  config = {
    systemd.services.NetworkManager-wait-online.enable = false;
    systemd.network.wait-online.enable = false;

    warnings = [
      (lib.mkIf (
        config.sifr.tailscale.enable && config.sifr.net.sifr0
      ) "${config.networking.hostName} has Tailscale and Nebula enabled! May cause issues.")
    ];
  };
}
