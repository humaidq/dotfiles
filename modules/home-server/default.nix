{ lib, ... }:
{
  imports = [
    ./nix.nix
    ./ai.nix
    ./misc.nix
    ./media.nix
    ./adguard.nix
    ./web-server.nix
    ./keycloak.nix
    ./nextcloud.nix
  ];

  options.sifr.home-server = {
    enable = lib.mkEnableOption "home server setup";
  };
}
