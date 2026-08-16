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
  gHeaders = ''
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Referrer-Policy "strict-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
  '';
  proxyHeaders = ''
    proxy_redirect off;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For "";
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
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
      recommendedProxySettings = false;
      recommendedOptimisation = true;
      additionalModules = [ pkgs.nginxModules.fancyindex ];
      appendHttpConfig = proxyHeaders;
      virtualHosts = lib.mkMerge [
        #(mkRP "" "8082")
        (mkRP "cache" "5000")
        (mkRP "hydra" "3300")
        (mkRP "vault" "8222")
        (mkRP "grafana" "3000")
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
              proxyPass = "http://10.20.0.164:8073";
              proxyWebsockets = true;
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
              proxy_set_header X-Forwarded-For   "";
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
        (lib.mkIf cfg.unifi.enable {
          # The controller UI. Unlike everything else here the backend is
          # HTTPS: the appliance terminates TLS itself with a self-signed
          # certificate and cannot be told not to, so this proxies to https://
          # and skips verification. Websockets carry the live device state, and
          # firmware uploads are large enough that the body limit has to go.
          #
          # Only the UI is proxied. Access point adoption talks to the inform
          # port directly on the LAN and never comes through nginx.
          "unifi.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              proxyPass = "https://127.0.0.1:${toString cfg.unifi.uiPort}";
              proxyWebsockets = true;

              # The headers have to be repeated here rather than inherited from
              # appendHttpConfig. nginx only inherits proxy_set_header from an
              # outer level if the current level sets none of its own, and
              # proxyWebsockets puts Upgrade and Connection in this location —
              # which silently drops every header from the http block, Host
              # included.
              #
              # Host is the one that matters. The appliance refuses a websocket
              # whose Origin does not match the Host it was asked for, so with
              # Host left at 127.0.0.1:11443 and the browser sending an Origin
              # of unifi.alq.ae it answers 500 on /api/ws/system. Plain requests
              # are unaffected, which is why the page loads its title and then
              # renders nothing.
              #
              # Connection is deliberately absent: appendHttpConfig pins it to
              # "" for keepalive, and setting it again here would send it
              # alongside the upgrade value rather than replacing it.
              extraConfig = ''
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For "";
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Host $host;

                # The appliance terminates TLS itself with a self-signed
                # certificate and cannot be told not to.
                proxy_ssl_verify off;
                proxy_ssl_server_name on;

                # Firmware and backup uploads.
                client_max_body_size 0;
              '';
            };
          };
        })
      ];
    };
  };
}
