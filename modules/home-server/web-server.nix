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
        (mkRP "dns" "3333")
        (mkRP "vault" "8222")
        (mkRP "grafana" "3000")
        (mkRP "ai" "2343")
        (mkRP "ollama" "11434")
        (mkRP "deluge" "8112")
        (mkRP "radarr" "7878")
        (mkRP "sonarr" "8989")
        (mkRP "prowlarr" "9696")
        (mkRP "bazarr" "6767")
        (mkRP "hydra" "3300")
        (mkRP "catalogue" (builtins.toString config.services.jellyseerr.port))
        (mkRP "books" "5555")
        (mkRP "audiobooks" "8000")
        (mkRP "tv" "8096")
        (mkRP "recipes" "9000")
        (mkRP "pdf" "8084")
        (mkRP "yt" "4747")
        (mkRP "search" "4848")
        (mkRP "git" "3939")
        # (mkRP "seafile" "3014")
        (mkRP "reddit" "3014")
        (mkRP "dav" "5232")
        (mkRP "webdav" "8477")
        (mkRP "onlyoffice" "3015")

        {
          "cloud.alq.ae" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;
          };
          "wiki.alq.ae" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;
          };
          "paperless.alq.ae" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;

            extraConfig = ''
              # allow large file uploads
              client_max_body_size 50000M;
                # These configuration options are required for WebSockets to work.
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";

                proxy_redirect off;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Host $server_name;
                add_header Referrer-Policy "strict-origin-when-cross-origin";
            '';
            locations."/" = {
              proxyPass = "http://127.0.0.1:28981";
              extraConfig = '''';
            };
          };
          "img.alq.ae" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;

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
          "${config.services.invidious.domain}" = {
            inherit (tls) sslCertificate sslCertificateKey forceSSL;
            enableACME = false;
          };
          "${config.services.authentik.nginx.host}" = {
            inherit (tls) sslCertificate sslCertificateKey;
            forceSSL = lib.mkForce true;
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
            {
              "YouTube" = {
                description = "Ad-free YouTube (Invidious)";
                href = "https://yt.alq.ae/";
                siteMonitor = "https://yt.alq.ae";
                icon = "mdi-youtube";
              };
            }
            {
              "Reddit" = {
                description = "Fast Reddit (RedLib)";
                href = "https://reddit.alq.ae/";
                siteMonitor = "https://reddit.alq.ae";
                icon = "mdi-reddit";
              };
            }
          ];
        }
        {
          "Services" = [
            {
              "Search" = {
                description = "Meta Search Engine (Searxng)";
                href = "https://search.alq.ae/";
                siteMonitor = "https://search.alq.ae/";
                icon = "mdi-search-web";
              };
            }
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
              "AI" = {
                description = "Local AI";
                href = "https://ai.alq.ae/";
                siteMonitor = "https://ai.alq.ae/";
                icon = "mdi-creation";
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
            {
              "Cloud" = {
                description = "Drive Storage & Office Suite";
                href = "https://cloud.alq.ae/";
                siteMonitor = "https://cloud.alq.ae/";
                icon = "mdi-apple-icloud";
              };
            }
            {
              "Paperless" = {
                description = "Document Management System";
                href = "https://paperless.alq.ae/";
                siteMonitor = "https://paperless.alq.ae/";
                icon = "mdi-leaf-circle";
              };
            }
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
                description = "eBooks Library (Kavita)";
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
          "Backend & Servers" = [
            {
              "Single Sign-On" = {
                description = "Local Identity Provider (Authentik)";
                href = "https://auth.alq.ae/";
                siteMonitor = "https://auth.alq.ae/";
                icon = "mdi-account-box-multiple";
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
