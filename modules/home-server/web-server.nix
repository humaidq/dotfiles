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
          # Internal only, like the rest of alq.ae: the certificate comes from
          # step-ca and the name resolves through blocky and the nebula host
          # map, so nothing outside the LAN or the mesh can reach it.
          #
          # proxyWebsockets because search results stream over a websocket
          # upgrade on /. Without it the page renders and the search box
          # silently returns nothing. mkRP is not used for the same reason —
          # it has no websocket support.
          "hister.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              proxyPass = "http://127.0.0.1:4433";
              proxyWebsockets = true;
            };
          };
          # Internal only, like hister above and for the same reasons. Written
          # out rather than going through mkRP because every subscriber holds a
          # connection open — a websocket for the app, an SSE or JSON stream
          # for the web app and the CLI — and mkRP has neither websocket
          # support nor any way to raise the timeout that would cut them.
          "ntfy.alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              proxyPass = "http://127.0.0.1:2586";
              proxyWebsockets = true;
              extraConfig = ''
                # Repeated from appendHttpConfig rather than inherited, for the
                # reason spelled out at unifi.alq.ae below: proxyWebsockets
                # puts Upgrade and Connection in this location, and nginx only
                # inherits proxy_set_header from an outer level when the
                # current level sets none of its own. Connection is left out on
                # purpose — here it carries the upgrade value.
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For "";
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Host $host;

                # ntfy sends a keepalive down an idle subscription every 45s,
                # so three minutes clears the gap comfortably. The 60s default
                # from appendHttpConfig does not: it drops every subscriber a
                # minute after they connect, which the app papers over by
                # reconnecting and which the web app shows as nothing at all.
                proxy_read_timeout 3m;

                # Without this nginx accumulates the stream in its own buffers
                # and hands notifications over in batches instead of as they
                # are published, which is the whole point of the service.
                proxy_buffering off;

                # Above ntfy's own 15M per-file attachment limit, so an
                # oversized upload is refused by ntfy with an error the client
                # can read rather than by nginx with a bare 413.
                client_max_body_size 20M;
              '';
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
          # Mirrors the public vhost on hisn, down to the same page directory,
          # because which of the two answers is decided by where the client is
          # rather than by what it asked for: nebula hands every node a host
          # entry pointing cache.huma.id at this machine, so anoa and the rest
          # of the mesh land here and hisn only ever sees the outside world.
          # Without these two locations the same URL gave harmonia's own
          # generated index inside and the page below outside.
          #
          # `= /` is an exact match, so it takes the bare root and nothing
          # else; every real cache request (/nix-cache-info, *.narinfo, /nar/*)
          # still falls to the prefix match below and reaches harmonia. Nix
          # never fetches / itself, so no substituter is affected by this.
          "cache.huma.id" = {
            inherit (tls) forceSSL;
            enableACME = true;
            locations = {
              "/" = {
                proxyPass = "http://127.0.0.1:5000";
              };
              "= /" = {
                root = ./cache-page;
                extraConfig = ''
                  index index.html;
                  try_files /index.html =404;
                '';
              };
              # The page's background and logo. Needed as its own location for
              # the same reason the exact match above is: with only `= /` the
              # img and background-image requests are prefix matches and go to
              # harmonia, which 404s them.
              "~* \\.jpeg$" = {
                root = ./cache-page;
              };
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
