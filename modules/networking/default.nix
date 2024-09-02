{
  imports = [
    ./tailscale.nix
    ./nebula.nix
    ./time.nix
    ./dns.nix
  ];
  config = {

    systemd.services.NetworkManager-wait-online.enable = false;
    systemd.network.wait-online.enable = false;

  };
}
