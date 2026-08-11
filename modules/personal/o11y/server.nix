{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.o11y.server;

  # Grafana's file provider walks a directory rather than reading a single
  # file, so the one dashboard this flake owns is handed over inside a farm of
  # its own instead of by path.
  dashboards = pkgs.linkFarm "grafana-dashboards" [
    {
      name = "router.json";
      path = ../../router/dashboard.json;
    }
  ];
in
{
  options.sifr.personal.o11y.server = {
    enable = lib.mkEnableOption "observability server using Grafana and Prometheus";
  };
  config = lib.mkIf cfg.enable {
    services.grafana = {
      enable = true;

      # The router dashboard is provisioned from the checked-in export rather
      # than living only in Grafana's database. It is the one dashboard whose
      # panels reference metrics this flake defines — the qos-mark rule
      # counters and the CAKE tin stats from modules/router/qos-metrics.nix —
      # so a metric rename that lands without the matching panel edit should
      # show up in review rather than as an empty graph weeks later.
      #
      # The tradeoff is that this dashboard becomes read-only in the UI:
      # allowUiUpdates is false, so edits have to be made to the JSON. To go
      # back to editing in the browser, flip it to true and re-export the file
      # afterwards — Grafana will still overwrite UI changes on restart, so the
      # file has to be kept in step either way.
      #
      # Grafana 13 registers dashboard.grafana.app v0alpha1/v1/v1beta1 and not
      # v2, which is the schema this export is written in. It loads regardless:
      # the provisioner converts it on read and logs a "failed to update
      # managedFields" line while doing so. That message is noise, not a
      # failure — the dashboard and every panel come back intact through the
      # API.
      provision.dashboards.settings.providers = [
        {
          name = "router";
          type = "file";
          allowUiUpdates = false;
          options.path = dashboards;
        }
      ];

      settings = {
        security.secret_key = "SW2YcwTIb9zpOOhoPsMm"; # default old key
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
          feedback_links_enabled = false;
        };
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
    services.prometheus = {
      enable = true;
      port = 9001;
      extraFlags = [ "--web.enable-remote-write-receiver" ];
      retentionTime = "30d";
    };
    services.loki = {
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

    networking.firewall.allowedTCPPorts = [
      9001
      3000
      3100
    ];
  };
}
