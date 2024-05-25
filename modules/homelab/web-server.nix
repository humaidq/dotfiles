{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.sifr.homelab.web-server;
in {
  options.sifr.homelab.web-server.enable = mkOption {
    description = "Enables home web server configuration";
    type = types.bool;
    default = false;
  };
  config = mkIf cfg.enable {
    services.caddy = {
      enable = true;
      virtualHosts."http://home.alq".extraConfig = ''
        reverse_proxy :8082
      '';
      virtualHosts."http://lldap.alq".extraConfig = ''
        reverse_proxy :17170
      '';
      virtualHosts."http://adguard.alq".extraConfig = ''
        reverse_proxy :3000
      '';
      virtualHosts."http://catalogue.alq".extraConfig = ''
        reverse_proxy :${builtins.toString config.services.jellyseerr.port}
      '';
      virtualHosts."http://books.alq".extraConfig = ''
        reverse_proxy :5000
      '';
      virtualHosts."http://audiobooks.alq".extraConfig = ''
        reverse_proxy :8000
      '';
      virtualHosts."http://tv.alq".extraConfig = ''
        reverse_proxy http://nas:8096
      '';
      virtualHosts."http://recipes.alq".extraConfig = ''
        reverse_proxy :9000
      '';
      virtualHosts."http://search.alq".extraConfig = ''
        reverse_proxy :3342
      '';
    };

    services.homepage-dashboard = {
      enable = true;
      listenPort = 8082;
      settings = {
        title = "home.alq";
        startURL = "http://home.alq";
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
                href = "http://tv.alq/";
                siteMonitor = "http://nas:8096";
                icon = "mdi-youtube-tv";
              };
            }
            {
              "Catalogue" = {
                description = "Movie Search Catalogue";
                href = "http://catalogue.alq/";
                siteMonitor = "http://catalogue.alq/";
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
                href = "http://recipes.alq/";
                siteMonitor = "http://recipes.alq/";
                icon = "mdi-silverware-fork-knife";
              };
            }
            {
              "Books" = {
                description = "eBooks Library";
                href = "http://books.alq/";
                siteMonitor = "http://books.alq/";
                icon = "mdi-bookshelf";
              };
            }
            {
              "Audio Books" = {
                description = "Audio Books Library";
                href = "http://audiobooks.alq/";
                siteMonitor = "http://audiobooks.alq/";
                icon = "mdi-book-music";
              };
            }
          ];
        }
        {
          "Services" = [
            {
              "NAS" = {
                description = "Network Attached Storage (Synology)";
                href = "http://nas.alq/";
                siteMonitor = "http://nas.alq/";
                icon = "mdi-nas";
              };
            }
            {
              "Gertruda" = {
                description = "Prusa MK3S+ 3D Printer";
                href = "http://gertruda.alq/";
                siteMonitor = "http://gertruda.alq/";
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
                href = "http://adguard.alq/";
                siteMonitor = "http://adguard.alq/";
                icon = "mdi-security";
              };
            }
            {
              "Etisalat" = {
                description = "Etisalat Router";
                href = "http://192.168.1.1/";
                siteMonitor = "http://192.168.1.1/";
                icon = "mdi-router-network";
              };
            }
          ];
        }
      ];
    };
  };
}
