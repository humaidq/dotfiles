{ config, lib, ... }:
let
  cfg = config.sifr.personal.o11y.client;
in
{
  options.sifr.personal.o11y.client = {
    enable = lib.mkEnableOption "observability client using Grafana Alloy";
    serverHost = lib.mkOption {
      type = lib.types.str;
      default = "oreamnos";
      description = "The hostname of the observability server";
    };
  };
  config = lib.mkIf cfg.enable {
    services.alloy.enable = true;

    # Created here rather than beside the one writer in modules/router, so that
    # the collector configured below always has a directory to read. A missing
    # one is not benign: node_exporter reports it as a collector error on every
    # scrape, on every host that never writes a textfile.
    systemd.tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-text-files 0755 root root -"
    ];
    # When it fails to send log, it doesn't quit. It usually takes a few
    # seconds to successfully send logs. 8 seconds should be enough.
    systemd.services.alloy = {
      reloadTriggers = [ "/etc/alloy/client.alloy" ];
      serviceConfig.TimeoutStopSec = 8;
    };
    environment.etc = lib.mkIf cfg.enable {
      "alloy/client.alloy" = {
        text = ''
          discovery.relabel "journal" {
            targets = []
            rule {
              source_labels = ["__journal__hostname"]
              target_label = "nodename"
            }
            rule {
              source_labels = ["__journal__systemd_unit"]
              target_label = "source"
            }
          }
          loki.source.journal "journal" {
            path = "/var/log/journal"
            relabel_rules = discovery.relabel.journal.rules
            forward_to = [loki.write.remote.receiver]
          }
          loki.write "remote" {
            endpoint {
              url = "http://${cfg.serverHost}:3100/loki/api/v1/push"
            }
          }

          // The textfile collector is enabled on every client, not just the
          // routers that currently write to it. An empty directory yields no
          // metrics and costs nothing, whereas gating it here would mean the
          // one module that needs it could not turn it on without reaching
          // into this file.
          prometheus.exporter.unix "default" {
            enable_collectors = ["systemd", "textfile"]
            textfile {
              directory = "/var/lib/prometheus-node-exporter-text-files"
            }
          }
          prometheus.scrape "default" {
            targets = prometheus.exporter.unix.default.targets
            forward_to = [prometheus.remote_write.default.receiver]
          }
          prometheus.remote_write "default" {
            endpoint {
              url = "http://${cfg.serverHost}:9001/api/v1/write"
            }
          }
        '';
        mode = "0644";
      };
    };
  };
}
