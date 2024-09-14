{ config, lib, ... }:
let

  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets."keycloak/password" = {
      sopsFile = ../../secrets/home-server.yaml;
    };
    services.keycloak = {
      enable = true;
      settings = {
        hostname = "sso.alq.ae";
        http-port = 3322;
        https-port = 43322;
        http-enabled = true;
        http-host = "127.0.0.1";
        proxy = "edge";
        proxy-headers = "xforwarded";

        # avoid conflict with mealie
        http-management-port = 9320;
      };
      database.passwordFile = config.sops.secrets."keycloak/password".path;
    };
  };
}
