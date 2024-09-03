{ lib, ... }:
{
  imports = [
    ./nix.nix
    ./media.nix
    ./adguard.nix
    ./web-server.nix
  ];

  options.sifr.home-server = {
    enable = lib.mkEnableOption "home server setup";
  };
}
