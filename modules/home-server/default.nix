{ lib, inputs, ... }:
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    ./nix.nix
    ./ai.nix
    ./misc.nix
    ./media.nix
    ./vaultwarden.nix
    ./blocky.nix
    ./web-server.nix
    ./nextcloud.nix
    ./db.nix
  ];

  options.sifr.home-server = {
    enable = lib.mkEnableOption "home server setup";
  };
}
