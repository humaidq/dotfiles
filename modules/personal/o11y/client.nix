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
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        prometheus.scrape "example" {
          targets    = [{ __address__ = "127.0.0.1:9100", instance = "host" }]
          forward_to = [prometheus.remote_write.default.receiver]
        }
      '';
      description = ''
        Alloy configuration appended verbatim to the generated client config.

        For collectors that cannot go through the textfile directory. That
        directory is 0755 root root and is written by root timers, so a service
        running under DynamicUser — router-web, which serves the uplink prober's
        /metrics — has no way to publish through it and has to be scraped over
        HTTP instead.

        Appended into the same file rather than dropped beside it because Alloy
        reads one config, and everything here shares its component namespace:
        that is what lets an added scrape forward to the
        prometheus.remote_write.default declared above without redeclaring the
        endpoint.
      '';
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
            forward_to = [loki.process.blocky.receiver]
          }

          // Promotes the querying client onto the stream, so that dashboards
          // can offer a device picker at all. Without it the only labels are
          // nodename and source, and a variable defined as
          // label_values({nodename="..."}, client_ip) returns an empty list —
          // which is exactly how the router dashboard's "Host IP" dropdown
          // came to be a free-text box that had to be filled in from memory.
          // Every panel still parses the field out of the line at query time;
          // this only adds the label the picker needs.
          //
          // Regex rather than stage.logfmt, despite the line being mostly
          // logfmt: blocky writes answer=CNAME (x), A (y) and
          // response_reason=RESOLVED (upstream) — values with spaces and
          // parentheses that a logfmt parser rejects outright. The dashboard's
          // existing queries paper over that with | __error__ = "", which
          // silently drops whatever failed to parse. A label built the same way
          // would silently omit devices. Anchoring on the two adjacent fields
          // matched 338 of 338 query lines in a sample, and client_names has
          // never been seen to contain a space.
          //
          // Scoped to blocky so the rest of the journal is not parsed for
          // fields it does not have. Hosts without the unit never match, so
          // this is inert everywhere except the routers.
          //
          // Cardinality is bounded by the DHCP pool — tens of devices per
          // network, not an open set — which is what makes a per-client label
          // safe here when it usually is not.
          loki.process "blocky" {
            forward_to = [loki.write.remote.receiver]

            stage.match {
              selector = "{source=\"blocky.service\"}"

              stage.regex {
                expression = "client_ip=(?P<client_ip>[^ ]+) client_names=(?P<client_names>[^ ]+)"
              }
              stage.labels {
                values = {
                  client_ip    = "",
                  client_names = "",
                }
              }
            }
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

          ${cfg.extraConfig}
        '';
        mode = "0644";
      };
    };
  };
}
