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
  gCsp = "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; font-src 'self' data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'";
  gHeaders = ''
    proxy_hide_header Content-Security-Policy;
    add_header Content-Security-Policy "${gCsp}" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Referrer-Policy "strict-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
  '';
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

        {
          "alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              root = ./homepage;
            };
          };
          "unifi.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              proxyPass = "https://127.0.0.1:18443";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_ssl_verify off;
              '';
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
          "g.huma.id" = {
            inherit (tls) forceSSL;
            enableACME = true;
            locations."/" = {
              proxyPass = "http://127.0.0.1:4232";
            };
            extraConfig = ''
              ${gHeaders}

              # allow large file uploads for lfs
              client_max_body_size 50000M;
            '';
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
          "webdav.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;

            locations."/" = {
              proxyPass = "http://127.0.0.1:8477";
            };
            extraConfig = ''
              # allow large file uploads for lfs
              client_max_body_size 50000M;
            '';
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
          # librespeed creates its own virtualHost, we just need to enable ACME
          "speed.alq.ae" = {
            enableACME = true;
          };
        }
      ];
    };
  };
}
