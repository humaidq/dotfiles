{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
  tls = {
    sslCertificate = config.sops.secrets."web/fullchain".path;
    sslCertificateKey = config.sops.secrets."web/privkey".path;
    forceSSL = true;
  };
  domain = "alq.ae";
  mkRP =
    sub: port:
    let
      dom = if (sub == "") then domain else "${sub}.${domain}";
    in
    {
      "${dom}" = {
        inherit (tls) sslCertificate sslCertificateKey forceSSL;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${port}";
        };
      };
    };
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets."web/fullchain" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nginx";
      mode = "600";
    };
    sops.secrets."web/privkey" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nginx";
      mode = "600";
    };

    services.nginx = {
      enable = true;
      recommendedZstdSettings = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      virtualHosts = lib.mkMerge [
        (mkRP "" "8082")

        (mkRP "cache" "5000")

        (mkRP "sso" "3322")

        (mkRP "adguard" "3333")

        (mkRP "vault" "8222")

        (mkRP "grafana" "3000")

        (mkRP "ai" "2343")

        (mkRP "ollama" "11434")

        (mkRP "deluge" "8112")

        (mkRP "radarr" "7878")

        (mkRP "sonarr" "8989")

        (mkRP "prowlarr" "9696")

        (mkRP "hydra" "3300")

        (mkRP "catalogue" (builtins.toString config.services.jellyseerr.port))

        (mkRP "books" "5555")

        (mkRP "audiobooks" "8000")

        (mkRP "tv" "8096")

        (mkRP "recipes" "9000")

        (mkRP "search" "3342")

        {
          "cloud.alq.ae" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;

          };
        }
      ];
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
