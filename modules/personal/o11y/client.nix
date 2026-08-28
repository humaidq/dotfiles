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
            forward_to = [loki.process.journal.receiver]
          }

          // Adds the handful of labels dashboards need to offer a picker at
          // all. Without them the only labels are nodename and source, and a
          // variable defined as label_values({nodename="..."}, client_ip)
          // returns an empty list — which is exactly how the router
          // dashboard's "Host IP" dropdown came to be a free-text box that had
          // to be filled in from memory. Every panel still parses the fields
          // out of the line at query time; these only add what the picker
          // needs. Each stage is scoped to one unit, so the rest of the
          // journal is never parsed for fields it does not have and a host
          // without that unit is unaffected.
          loki.process "journal" {
            forward_to = [loki.write.remote.receiver]

            // Regex rather than stage.logfmt, despite the line being mostly
            // logfmt: blocky writes answer=CNAME (x), A (y) and
            // response_reason=RESOLVED (upstream) — values with spaces and
            // parentheses that a logfmt parser rejects outright. The
            // dashboard's existing queries paper over that with
            // | __error__ = "", which silently drops whatever failed to parse.
            // A label built the same way would silently omit devices.
            // Anchoring on the two adjacent fields matched 338 of 338 query
            // lines in a sample, and client_names has never been seen to
            // contain a space.
            //
            // Cardinality is bounded by the DHCP pool — tens of devices per
            // network, not an open set — which is what makes a per-client
            // label safe here when it usually is not. That reasoning does not
            // carry to hisn, whose blocky answers DoH for the open internet;
            // it is the same argument that keeps blocky_query_total off the
            // Prometheus side there.
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

            // nginx access lines, which hisn writes to the journal as JSON
            // (see hosts/hisn/metrics.nix). Same purpose as the block above:
            // a label the dashboard's vhost picker can enumerate, since
            // label_values only sees labels and never fields parsed at query
            // time. Every panel still parses the line for status, duration
            // and the rest.
            //
            // server_name and not the Host header. The two agree for almost
            // every request, but Host is whatever the client typed and would
            // let anyone spraying junk Host headers at the address create
            // Loki streams without limit. server_name is the block that
            // matched, so the set is as large as the nginx config and no
            // larger.
            //
            // Inert on hosts whose nginx logs the default combined format:
            // the JSON stage finds no fields, adds no labels and passes the
            // line through unchanged, which is also what happens to nginx's
            // error log on hisn.
            stage.match {
              selector = "{source=\"nginx.service\"}"

              stage.json {
                expressions = {
                  server = "",
                }
              }
              stage.labels {
                values = {
                  server = "",
                }
              }
            }
          }
          // blocky's answer log, which is a FILE and not the journal.
          //
          // WHY THIS EXISTS AT ALL. blocky has exactly one queryLog, and on
          // 2026-08-28 the routers' was pointed at a CSV file so the peers page
          // could name an address with no PTR. The moment it stopped writing to
          // stdout it stopped reaching the journal, and every DNS panel on the
          // router dashboard — all of which select `|= "query resolved"` on the
          // journal stream — went to zero within one 15m window. This block is
          // what puts the data back in front of them.
          //
          // NO PARSING STAGE, deliberately, unlike the journal blocks above.
          // Those add labels only because a dashboard variable cannot enumerate
          // a field parsed at query time. Nothing here needs a picker: the file
          // records no client, so there is no per-device dropdown to populate,
          // and the columns that vary — the question and its answer — are
          // exactly the high-cardinality ones that must not become labels.
          //
          // THE FORMAT IS TAB-SEPARATED AND ITS FIELD COUNT VARIES, which is
          // worth knowing before writing a query against it. blocky does not
          // escape tabs inside the quoted answer column, so a row with several
          // answer records splits into more fields than one with a single A
          // record — 11, 15, 19 and 27 all occur in one day's file. What is
          // stable is the left-hand side: field 6 is always the question name,
          // and the last two are always the question type and the instance. Any
          // query here should anchor on those and never on a field counted from
          // the middle.
          //
          // Inert on a host that has no such directory, the same way the nginx
          // stage above is inert where nginx logs the combined format: the
          // match produces no targets and nothing is read.
          local.file_match "blocky_answers" {
            path_targets = [{
              __path__ = "/var/log/blocky-answers/*.log",
              nodename = "${config.networking.hostName}",
              source   = "blocky-answers",
            }]
          }

          // nodename is set from the Nix hostname rather than parsed out of the
          // line. The file's last column does carry the instance name, but the
          // journal stream sets nodename from __journal__hostname and the
          // dashboard's $network variable selects on it, so the two sources have
          // to agree on where that label comes from or the picker splits in two.
          loki.source.file "blocky_answers" {
            targets    = local.file_match.blocky_answers.targets
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

          ${cfg.extraConfig}
        '';
        mode = "0644";
      };
    };
  };
}
