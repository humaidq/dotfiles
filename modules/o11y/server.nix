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
      settings.server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        domain = "localhost";
      };
    };
    services.prometheus = lib.mkIf cfg.enable {
      enable = true;
      port = 9001;
      extraFlags = [ "--web.enable-remote-write-receiver" ];
      retentionTime = "30d";
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
    ];
  };
}
