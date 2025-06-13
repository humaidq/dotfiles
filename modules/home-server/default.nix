{
  lib,
  inputs,
  config,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    ./acme.nix
    ./blocky.nix
    ./dav.nix
    ./db.nix
    ./immich.nix
    ./media.nix
    ./misc.nix
    ./nix.nix
    ./vaultwarden.nix
    ./web-server.nix
  ];

  options.sifr.home-server = {
    enable = lib.mkEnableOption "home server setup";
    domains = lib.mkOption {
      type = with lib.types; listOf str;
      readOnly = true;
      default = [ ];
      description = "Domains served by the home server web instance.";
    };
  };

  config = {
    sifr.home-server.domains = lib.mkIf cfg.enable (
      builtins.attrNames config.services.nginx.virtualHosts
    );
  };
}
