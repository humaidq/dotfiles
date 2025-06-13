{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
  tls = {
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
        inherit (tls) forceSSL;
        enableACME = true;
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

    security.acme.acceptTerms = true;
    security.acme.defaults = {
      email = "local@alq.ae";
      server = "https://alq.ae:8443/acme/acme/directory";
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
        (mkRP "dns" "3333")
        (mkRP "vault" "8222")
        (mkRP "grafana" "3000")
        (mkRP "deluge" "8112")
        (mkRP "radarr" "7878")
        (mkRP "sonarr" "8989")
        (mkRP "prowlarr" "9696")
        (mkRP "bazarr" "6767")
        (mkRP "hydra" "3300")
        (mkRP "catalogue" (builtins.toString config.services.jellyseerr.port))
        (mkRP "tv" "8096")
        (mkRP "pdf" "8084")
        (mkRP "git" "3939")
        (mkRP "dav" "5232")
        (mkRP "webdav" "8477")

        {
          "sdr.alq.ae" = {
            enableACME = true;
            locations."/" = {
              proxyPass = "http://192.168.1.164:8073";
            };
          };
          "img.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;

            extraConfig = ''
              # allow large file uploads
              client_max_body_size 50000M;

              # Set headers
              proxy_set_header Host              $host;
              proxy_set_header X-Real-IP         $remote_addr;
              proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # enable websockets: http://nginx.org/en/docs/http/websocket.html
              proxy_http_version 1.1;
              proxy_set_header   Upgrade    $http_upgrade;
              proxy_set_header   Connection "upgrade";
              proxy_redirect     off;

              # set timeout
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              send_timeout       600s;
            '';
            locations."/" = {
              proxyPass = "http://127.0.0.1:3011";
            };
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
            provider = "custom";
            url = "https://search.alq.ae/search?q=";
            target = "_blank";
            suggestionUrl = "https://search.alq.ae/autocompleter?q=";
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
                description = "Movie Search Catalogue (Jellyseerr)";
                href = "https://catalogue.alq.ae/";
                siteMonitor = "https://catalogue.alq.ae/";
                icon = "mdi-movie-search";
              };
            }
          ];
        }
        {
          "Services" = [
            {
              "Vault" = {
                description = "Password Manager (Vaultwarden)";
                href = "https://vault.alq.ae/";
                siteMonitor = "https://vault.alq.ae/";
                icon = "mdi-shield-key";
              };
            }
            {
              "Git" = {
                description = "Software Forge (Forgejo)";
                href = "https://git.alq.ae/";
                siteMonitor = "https://git.alq.ae/";
                icon = "mdi-git";
              };
            }
            {
              "Stirling PDF" = {
                description = "All-in-one PDF Toolbox";
                href = "https://pdf.alq.ae/";
                siteMonitor = "https://pdf.alq.ae/";
                icon = "mdi-file-pdf-box";
              };
            }
          ];
        }
        {
          "Resources" = [
            {
              "Images" = {
                description = "Photo Backups & Albums (Immich)";
                href = "https://img.alq.ae/";
                siteMonitor = "https://img.alq.ae/";
                icon = "mdi-image-album";
              };
            }
          ];
        }
        {
          "Backend & Servers" = [
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
            {
              "Local DNS" = {
                description = "DNS+DoH with ad-blocking (blocky)";
                href = "https://dns.alq.ae/";
                siteMonitor = "https://dns.alq.ae/";
                icon = "mdi-security";
              };
            }
            {
              "Local NTP" = {
                description = "Your local time-keeper";
                href = "https://time.alq.ae/";
                siteMonitor = "https://time.alq.ae/";
                icon = "mdi-clock-time-two";
              };
            }
            {
              "Synology NAS" = {
                description = "Network Attached Storage (Synology)";
                href = "https://nas.alq.ae/";
                siteMonitor = "https://nas.alq.ae/";
                icon = "mdi-nas";
              };
            }
          ];
        }
        {
          "Media Services" = [
            {
              "Sonarr" = {
                description = "TV Shows Automation";
                href = "https://sonarr.alq.ae/";
                siteMonitor = "https://sonarr.alq.ae/";
                icon = "mdi-movie-search";
              };
            }
            {
              "Radarr" = {
                description = "Movies Automation";
                href = "https://radarr.alq.ae/";
                siteMonitor = "https://radarr.alq.ae/";
                icon = "mdi-movie-search";
              };
            }
            {
              "Prowlarr" = {
                description = "Torrent Indexing Service";
                href = "https://prowlarr.alq.ae/";
                siteMonitor = "https://prowlarr.alq.ae/";
                icon = "mdi-format-list-group";
              };
            }
            {
              "Bazarr" = {
                description = "Captions Fetching Service";
                href = "https://bazarr.alq.ae/";
                siteMonitor = "https://bazarr.alq.ae/";
                icon = "mdi-closed-caption";
              };
            }
            {
              "Deluge" = {
                description = "Torrent Download Client";
                href = "https://deluge.alq.ae/";
                siteMonitor = "https://deluge.alq.ae/";
                icon = "mdi-download-circle";
              };
            }
          ];
        }
      ];
    };
  };
}
