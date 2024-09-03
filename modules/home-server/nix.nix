{ lib, config, ... }:
let
  cfg = config.sifr.home-server;
in
{
  config = {

    services.hydra = lib.mkIf cfg.enable {
      enable = true;
      hydraURL = "http://serow:3300";
      port = 3300;
      notificationSender = "hydra@localhost"; # e-mail of hydra service
      buildMachinesFiles = [ ];
      # you will probably also want, otherwise *everything* will be built from scratch
      useSubstitutes = true;
    };

    nix.settings.allowed-uris = lib.mkIf cfg.enable [
      "github:"
      "git+https://github.com/"
      "git+ssh://github.com/"
      "https://github.com/"
    ];

    nix.settings.trusted-users = lib.mkIf cfg.enable [
      "root"
      "hydra"
      "hydra-www"
    ];

    services.harmonia = lib.mkIf cfg.enable {
      enable = true;
      signKeyPath = "/var/cache-priv-key.pem";
      settings = {
        bind = "0.0.0.0:5000";
        priority = 50;
      };
    };

  };
}
