{
  config,
  lib,
  pkgs,
  ...
}:
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
    sops.secrets."web/files-htpasswd" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nginx";
      mode = "640";
    };

    security.acme.acceptTerms = true;
    security.acme.defaults = {
      email = "local@alq.ae";
      server = "https://alq.ae:8443/acme/acme/directory";
    };

    services.nginx = {
      enable = true;
      # recommendedZstdSettings = true; # bugs, renamed to experimentalZstdSettings
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      additionalModules = [ pkgs.nginxModules.fancyindex ];
      virtualHosts = lib.mkMerge [
        #(mkRP "" "8082")
        (mkRP "cache" "5000")
        (mkRP "hydra" "3300")
        (mkRP "dns" "3333")
        (mkRP "vault" "8222")
        (mkRP "grafana" "3000")
        (mkRP "deluge" "8112")
        (mkRP "radarr" "7878")
        (mkRP "sonarr" "8989")
        (mkRP "prowlarr" "9696")
        (mkRP "catalogue" (builtins.toString config.services.jellyseerr.port))
        (mkRP "tv" "8096")
        (mkRP "pdf" "8084")
        (mkRP "dav" "5232")
        (mkRP "webdav" "8477")

        {
          "alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              root = ./homepage;
            };
          };
          "ai.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              proxyPass = "http://127.0.0.1:2343";
              proxyWebsockets = true;
            };
          };
          "wiki.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
          };
          "cache.huma.id" = {
            inherit (tls) forceSSL;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://127.0.0.1:5000";
            };
          };
          "sdr.alq.ae" = {
            enableACME = true;
            locations."/" = {
              proxyPass = "http://192.168.1.164:8073";
            };
          };
          "git.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;

            locations."/" = {
              proxyPass = "http://127.0.0.1:3939";
            };
            extraConfig = ''
              # allow large file uploads for lfs
              client_max_body_size 50000M;
            '';
          };
          "files.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;

            basicAuthFile = config.sops.secrets."web/files-htpasswd".path;
            locations."/" = {
              root = "/mnt/humaid/files";
              extraConfig = ''
                # plain directory listing
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
                # theme
                fancyindex on;
                fancyindex_exact_size off;
                fancyindex_localtime on;
              '';
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

              # set timeout
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              send_timeout       600s;
            '';
            locations."/" = {
              proxyPass = "http://127.0.0.1:3011";
              proxyWebsockets = true;
            };
          };
        }
      ];
    };
  };
}
