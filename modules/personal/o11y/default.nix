{ lib, config, ... }:
let
  cfg = config.sifr.personal.o11y;
  enabled = cfg.client.enable || cfg.server.enable;
in
{
  imports = [
    ./client.nix
    ./server.nix
  ];
  config = lib.mkIf enabled { };
}
