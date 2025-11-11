{ config, lib, ... }:
let
  cfg = config.sifr.o11y.server;
in
{
  options.sifr.o11y.server = {
    enable = lib.mkEnableOption "observability server using Grafana and Prometheus";
  };
  config = {
    services.grafana = lib.mkIf cfg.enable {
      enable = true;
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = 3000;
          domain = "localhost";
        };
        smtp = {
          enabled = true;
          host = "smtp.migadu.com:587";
          user = "oreamnos@alq.ae";
          from_address = "oreamnos@alq.ae";
          from_name = "Grafana";
          startTLS_policy = "MandatoryStartTLS";
          password = "$__file{${config.sops.secrets."smtp/oreamnos_pass".path}}";
        };
      };
    };
    services.prometheus = lib.mkIf cfg.enable {
      enable = true;
      port = 9001;
      extraFlags = [ "--web.enable-remote-write-receiver" ];
      retentionTime = "30d";
      scrapeConfigs = [
        {
          job_name = "blocky";
          static_configs = [
            {
              targets = [ "localhost:3333" ];
            }
          ];
        }
      ];
    };
    services.loki = lib.mkIf cfg.enable {
      enable = true;

      configuration = {
        auth_enabled = false;
        server.http_listen_port = 3100;
        common = {
          ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          replication_factor = 1;
          path_prefix = config.services.loki.dataDir;
        };
        schema_config.configs = [
          {
            from = "2024-08-18";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        storage_config.filesystem.directory = "${config.services.loki.dataDir}/chunks";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.enable [
      9001
      3000
      3100
    ];
  };
}
