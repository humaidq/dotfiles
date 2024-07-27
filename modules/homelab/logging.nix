{
  lib,
  config,
  ...
}: let
  cfg = config.sifr.homelab;
in {
  options.sifr.homelab = {
    log-server.enable = lib.mkEnableOption "log server using Grafana";
  };
  config = lib.mkIf cfg.log-server.enable {
    services.grafana = {
      enable = true;
      settings.server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        domain = "localhost";
      };
    };
    services.prometheus = {
      enable = true;
      port = 9001;
      globalConfig = {
        scrape_interval = "30s";
      };
      scrapeConfigs = [
        {
          job_name = "serow";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
            }
          ];
        }
      ];
      exporters = {
        node = {
          enable = true;
          enabledCollectors = ["systemd"];
          port = 9002;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [9001 3000];
  };
}
