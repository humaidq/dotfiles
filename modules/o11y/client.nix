{ config, lib, ... }:
let
  cfg = config.sifr.o11y.client;
in
{
  options.sifr.o11y.client = {
    enable = lib.mkEnableOption "observability client using Grafana Alloy";
  };
  config = {
    services.alloy.enable = true;
    environment.etc = lib.mkIf cfg.enable {
      "alloy/client.alloy" = {
        text = ''
          discovery.relabel "journal" {
            targets = []
            rule {
              source_labels = ["__journal__hostname"]
              target_label = "nodename"
            }
          }
          loki.source.journal "journal" {
            path = "/var/log/journal"
            relabel_rules = discovery.relabel.journal.rules
            forward_to = [loki.write.remote.receiver]
          }
          loki.write "remote" {
            endpoint {
              url = "http://serow:3100/loki/api/v1/push"
            }
          }

          prometheus.exporter.unix "default" {
            enable_collectors = ["systemd"]
          }
          prometheus.scrape "default" {
            targets = prometheus.exporter.unix.default.targets
            forward_to = [prometheus.remote_write.default.receiver]
          }
          prometheus.remote_write "default" {
            endpoint {
              url = "http://serow:9001/api/v1/write"
            }
          }
        '';
        mode = "0644";
      };
    };
  };
}
