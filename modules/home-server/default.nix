{ lib, inputs, ... }:
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    ./acme.nix
    ./ai.nix
    ./blocky.nix
    ./dav.nix
    ./db.nix
    ./immich.nix
    ./media.nix
    ./misc.nix
    ./nextcloud.nix
    ./nix.nix
    ./vaultwarden.nix
    ./web-server.nix
    ./wiki.nix
  ];

  options.sifr.home-server = {
    enable = lib.mkEnableOption "home server setup";
  };
}
