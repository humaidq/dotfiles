{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.o11y.server;

  # Grafana's file provider walks a directory rather than reading a single
  # file, so the router dashboard is handed over inside a farm of its own
  # instead of by path. The rest live together in ./dashboards, which is
  # already a directory and needs no farm.
  routerDashboard = pkgs.linkFarm "grafana-router-dashboard" [
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

      # Everything Grafana shows is provisioned from this repo — dashboards,
      # datasources, alert rules, contact points, the notification policy and
      # the mute timings. Nothing is left living only in Grafana's database,
      # where it is invisible to review and survives only as long as
      # /var/lib/grafana does. Grafana 13 makes that failure mode concrete:
      # four dashboards created through the old UI never migrated into unified
      # storage and stopped being served at all, with their rows still sitting
      # in the legacy `dashboard` table.
      #
      # allowUiUpdates is false throughout, so every dashboard is read-only in
      # the browser and edits are made to the JSON here. To rework one in the
      # UI instead, flip the flag for its provider and re-export afterwards;
      # Grafana overwrites UI changes on restart otherwise, so the file has to
      # be kept in step either way.
      provision = {
        # Pinned by uid because every dashboard and alert rule below refers to
        # these datasources by uid, not by name. The uids match the ones the
        # live instance already had, so provisioning adopts those rows in place
        # rather than creating a second pair that nothing points at.
        datasources.settings.datasources = [
          {
            name = "prometheus";
            uid = "edy9njbuhd4aob";
            type = "prometheus";
            access = "proxy";
            url = "http://localhost:9001";
            isDefault = true;
            jsonData.httpMethod = "POST";
          }
          {
            name = "loki";
            uid = "cdy9o5iluz3swd";
            type = "loki";
            access = "proxy";
            url = "http://localhost:3100";
          }
        ];

        # Two providers only because the router dashboard lives in
        # modules/router/ next to the metrics it charts, and a file provider
        # takes a directory rather than a path. Renaming an existing provider
        # makes Grafana re-register its dashboards and collide on uid, so
        # "router" stays put.
        #
        # The router dashboard's panels reference metrics this flake defines —
        # the qos-mark rule counters and the CAKE tin stats from
        # modules/router/qos-metrics.nix — so a metric rename that lands
        # without the matching panel edit shows up in review rather than as an
        # empty graph weeks later.
        #
        # ./dashboards mixes schemas: groundwave.json is v2 (hand-built for the
        # tabbed layout), the rest are classic v1 community exports. The
        # provisioner reads each file on its own, so the mix is fine.
        #
        # Grafana 13 registers dashboard.grafana.app v0alpha1/v1/v1beta1 and
        # not v2, which is the schema those are written in. They load
        # regardless: the provisioner converts it on read and logs a "failed to
        # update managedFields" line while doing so. That message is noise, not
        # a failure — the dashboard and every panel come back intact through
        # the API.
        dashboards.settings.providers = [
          {
            name = "router";
            type = "file";
            allowUiUpdates = false;
            options.path = routerDashboard;
          }
          {
            name = "sifr";
            type = "file";
            allowUiUpdates = false;
            options.path = ./dashboards;
          }
        ];

        # Kept as the YAML the provisioning export API emits, verbatim, so a
        # future re-export drops straight in without a translation step into
        # Nix. Regenerate with:
        #   curl -u <admin> \
        #     'http://oreamnos:3000/api/v1/provisioning/alert-rules/export?format=yaml'
        # and the matching contact-points/policies/mute-timings endpoints.
        #
        # rules.yaml names the folder "Main"; the provisioner creates it if it
        # is missing, so the folder needs no separate declaration.
        alerting = {
          rules.path = ./alerting/rules.yaml;
          contactPoints.path = ./alerting/contactPoints.yaml;
          policies.path = ./alerting/policies.yaml;
          muteTimings.path = ./alerting/muteTimings.yaml;
          templates.path = ./alerting/templates.yaml;
        };
      };

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
