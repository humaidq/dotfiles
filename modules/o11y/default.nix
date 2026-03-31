{ lib, config, ... }:
let
  cfg = config.sifr.o11y;
  enabled = cfg.client.enable || cfg.server.enable;
in
{
  imports = [
    ./client.nix
    ./server.nix
  ];
  config = lib.mkIf enabled {
    sifr.persist.dirs = [
      "/var/lib/grafana"
      "/var/lib/loki"
    ];
  };
}
