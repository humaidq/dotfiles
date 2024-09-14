{ config, lib, ... }:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.postgresql = {
      ensureUsers = [
        {
          name = "vaultwarden";
          ensureDBOwnership = true;
        }
      ];
      ensureDatabases = [ "vaultwarden" ];
    };
    sops.secrets."vaultwarden/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "vaultwarden";
      mode = "600";
    };
    services.vaultwarden = {
      enable = true;
      dbBackend = "postgresql";
      config = {
        DOMAIN = "https://vault.alq.ae";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        databaseUrl = "postgres:///vaultwarden?host=/var/run/postgresql";

        # Mail
        SMTP_HOST = "in-v3.mailjet.com";
        SMTP_PORT = 25;
        SMTP_SECURITY = "starttls";
        SMTP_FROM = "server@alq.ae";
        SMTP_FROM_NAME = "alq.ae Vaultwarden Server";
      };
      environmentFile = "${config.sops.secrets."vaultwarden/env".path}";
    };
  };
}
