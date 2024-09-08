{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets."web/fullchain" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "caddy";
      mode = "600";
    };
    sops.secrets."web/privkey" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "caddy";
      mode = "600";
    };
    services.caddy =
      let
        tls = ''
          tls ${config.sops.secrets."web/fullchain".path} ${config.sops.secrets."web/privkey".path}
        '';
      in
      {
        enable = true;
        #extraConfig = tls;
        virtualHosts."alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :8082
        '';
        virtualHosts."lldap.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :17170
        '';
        virtualHosts."cache.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :5000
        '';
        virtualHosts."adguard.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :3333
        '';
        virtualHosts."grafana.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :3000
        '';

        virtualHosts."deluge.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :8112
        '';
        virtualHosts."radarr.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :7878
        '';
        virtualHosts."sonarr.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :8989
        '';
        virtualHosts."prowlarr.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :9696
        '';
        virtualHosts."hydra.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :3300
        '';

        virtualHosts."catalogue.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :${builtins.toString config.services.jellyseerr.port}
        '';
        virtualHosts."books.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :5555
        '';
        virtualHosts."audiobooks.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :8000
        '';
        virtualHosts."tv.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :8096
        '';
        virtualHosts."recipes.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :9000
        '';
        virtualHosts."search.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy :3342
        '';
        virtualHosts."gertruda.alq.ae".extraConfig = ''
          ${tls}
          reverse_proxy 192.168.1.40:80
        '';
      };

    services.homepage-dashboard = {
      enable = true;
      listenPort = 8082;
      settings = {
        title = "alq.ae";
        startURL = "https://alq.ae";
        background = "https://images.unsplash.com/photo-1502790671504-542ad42d5189?auto=format&fit=crop&w=2560&q=80";
      };
      widgets = [
        {
          search = {
            provider = "duckduckgo";
            target = "_blank";
            showSearchSuggestions = true;
          };
        }
        {
          openmeteo = {
            latitude = "25.4018";
            longitude = "55.4788";
            timezone = "Asia/Dubai";
            units = "metric";
            cache = 15;
          };
        }
      ];
      services = [
        {
          "Entertainment" = [
            {
              "TV" = {
                description = "Movie Streaming (Jellyfish)";
                href = "https://tv.alq.ae/";
                siteMonitor = "https://tv.alq.ae";
                icon = "mdi-youtube-tv";
              };
            }
            {
              "Catalogue" = {
                description = "Movie Search Catalogue";
                href = "https://catalogue.alq.ae/";
                siteMonitor = "https://catalogue.alq.ae/";
                icon = "mdi-movie-search";
              };
            }
          ];
        }
        {
          "Resources" = [
            {
              "Recipes" = {
                description = "Recipe Book (Mealie)";
                href = "https://recipes.alq.ae/";
                siteMonitor = "https://recipes.alq.ae/";
                icon = "mdi-silverware-fork-knife";
              };
            }
            {
              "Books" = {
                description = "eBooks Library";
                href = "https://books.alq.ae/";
                siteMonitor = "https://books.alq.ae/";
                icon = "mdi-bookshelf";
              };
            }
            {
              "Audio Books" = {
                description = "Audio Books Library";
                href = "https://audiobooks.alq.ae/";
                siteMonitor = "https://audiobooks.alq.ae/";
                icon = "mdi-book-music";
              };
            }
          ];
        }
        {
          "Services" = [
            {
              "Synology NAS" = {
                description = "Network Attached Storage (Synology)";
                href = "https://nas.alq.ae/";
                siteMonitor = "https://nas.alq.ae/";
                icon = "mdi-nas";
              };
            }
            {
              "Grafana" = {
                description = "Observability Platform";
                href = "https://grafana.alq.ae/";
                siteMonitor = "https://grafana.alq.ae/";
                icon = "mdi-chart-box-multiple";
              };
            }
            {
              "Hydra" = {
                description = "Hydra CI Server";
                href = "https://hydra.alq.ae/";
                siteMonitor = "https://hydra.alq.ae/";
                icon = "mdi-autorenew";
              };
            }
            {
              "Cache" = {
                description = "Nix Binary Cache";
                href = "https://cache.alq.ae/";
                siteMonitor = "https://cache.alq.ae/";
                icon = "mdi-database-clock";
              };
            }
            {
              "Gertruda" = {
                description = "Prusa MK3S+ 3D Printer";
                href = "https://gertruda.alq.ae/";
                siteMonitor = "https://gertruda.alq.ae/";
                icon = "mdi-printer-3d-nozzle";
              };
            }
          ];
        }
        {
          "Administration" = [
            {
              "AdGuard" = {
                description = "Network DNS & DHCP server (AdGuard Home)";
                href = "https://adguard.alq.ae/";
                siteMonitor = "https://adguard.alq.ae/";
                icon = "mdi-security";
              };
            }
          ];
        }
      ];
    };
  };
}
