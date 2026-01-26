{
  pkgs,
  inputs,
  ...
}:
let
  humaid-site = inputs.humaid-site.packages.${pkgs.stdenv.hostPlatform.system}.default;
  security-headers = ''
    add_header Strict-Transport-Security "max-age=31536000" always;
    # Enable CSP for your services.
    #add_header Content-Security-Policy "script-src 'self'; object-src 'none'; base-uri 'none';" always;
    add_header X-Content-Type-Options "nosniff" always;
    # clickjacking protection
    add_header X-Frame-Options "DENY" always;
    # disable FLOC
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Referrer-Policy "strict-origin" always;
    proxy_hide_header X-Powered-By;
    proxy_hide_header server;
    proxy_hide_header X-Runtime;
    # legacy
    add_header X-XSS-Protection "1; mode=block" always;
  '';
  error-pages = ''
    proxy_intercept_errors on;
    error_page 502 = /_error/502.html;
    error_page 504 = /_error/504.html;
  '';
  error-pages-loc = ''
    location = /_error/429.html {
      internal;
      default_type text/html;
      alias ${./error-pages/429.html};
    }

    location = /_error/502.html {
      internal;
      default_type text/html;
      alias ${./error-pages/502.html};
    }
    location = /_error/504.html {
      internal;
      default_type text/html;
      alias ${./error-pages/504.html};
    }
  '';
in
{
  config = {
    networking.firewall.allowedTCPPorts = [
      443
      80
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = "acme@huma.id";
    };

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      recommendedBrotliSettings = true;

      appendHttpConfig = ''
        ${security-headers}

        map $request_method $limit_post {
          default "";
          POST    $binary_remote_addr;
        }

        # Rate limit
        limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
        limit_req_zone $binary_remote_addr zone=expensive:10m rate=1r/s;
        limit_req_zone $limit_post zone=post:10m rate=2r/s;
        limit_req_status 429;
        error_page 429 = /_error/429.html;
      '';

      virtualHosts = {
        "huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations."/" = {
            root = humaid-site;
            extraConfig = ''
              error_page 404 /404.html;

              limit_req zone=general burst=50 nodelay;
            '';
          };
        };

        "qsl.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations."/" = {
            proxyPass = "http://127.0.0.1:8181";
            extraConfig = ''
              ${error-pages}

              proxy_hide_header X-Frame-Options;
              proxy_set_header X-Request-ID $request_id;

              # general
              limit_req zone=general burst=30 nodelay;

              # for any post
              limit_req zone=post burst=2 nodelay;
            '';
          };
        };

        "f.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations."/" = {
            root = "/srv/files";
            extraConfig = ''
              # be explicit, already off by default
              autoindex off;

              # prevent scraping/bruteforcing
              limit_req zone=expensive burst=10;
            '';
          };
        };

        "g.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations."/" = {
            proxyPass = "http://10.10.0.12:4232";
            extraConfig = ''
              ${error-pages}

              # general
              limit_req zone=general burst=30 nodelay;

              # for any post
              limit_req zone=post burst=2 nodelay;
            '';
          };
        };

        "cache.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = {
            "/" = {
              proxyPass = "http://10.10.0.12:5000";
            };
            "= /" = {
              root = "${./cache-page}";
            };
            "~* \\.jpeg$" = {
              root = "${./cache-page}";
            };
          };
        };

        "dns.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations = {
            "/dns-query" = {
              proxyPass = "http://127.0.0.1:3333";
              extraConfig = ''
                proxy_intercept_errors off;
                proxy_request_buffering off;
                proxy_buffering off;
                proxy_set_header Host $host;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_http_version 1.1;
                proxy_set_header Connection "";
              '';
            };
            "/" = {
              return = "301 https://lighthouse.huma.id";
            };
          };
        };

        "sdr.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = {
            "/" = {
              proxyPass = "http://sdr.alq.ae";

              extraConfig = ''
                ${error-pages}

                proxy_set_header Host sdr.alq.ae;
              '';
            };
          };
        };

        "www.huma.id" = {
          serverAliases = [
            "humaidq.ae"
            "www.humaidq.ae"
          ];
          forceSSL = true;
          enableACME = true;
          globalRedirect = "huma.id";
        };

        "www.alq.ae" = {
          enableACME = true;
          forceSSL = true;
          serverAliases = [
            "alq.ae"
            "tv.alq.ae"
            "catalogue.alq.ae"
            "wiki.alq.ae"
            "vault.alq.ae"
            "git.alq.ae"
            "grafana.alq.ae"
            "cache.alq.ae"
            "deluge.alq.ae"
            "pdf.alq.ae"
            "dav.alq.ae"
            "webdav.alq.ae"
            "img.alq.ae"
            "ai.alq.ae"
            "unifi.alq.ae"
            "files.alq.ae"
            "speed.alq.ae"
          ];
          locations."/" = {
            root = ./sifr0-error;
            tryFiles = "$uri =403";
            extraConfig = ''
              error_page 403 /index.html;
            '';
          };
        };

        "sarim.huma.id" = {
          root = "/srv/sarim";
          forceSSL = true;
          enableACME = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          basicAuthFile = pkgs.writeText "sarim-htpasswd" ''
            sarim:$2a$14$QbtiHp/b2Iaue/5At71guutf4XIeA2qANorbuI7dVTSCFli4KBfJa
          '';

          locations."~ \\.bundle$" = {
            extraConfig = "default_type application/octet-stream;";
          };
        };

        # Fun stuff
        "bot.huma.id" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            extraConfig = ''
              default_type text/plain;
              return 200 'beep boop';
            '';
          };
        };
        "car.huma.id" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            extraConfig = ''
              default_type text/plain;
              return 200 'vroom vroom';
            '';
          };
        };
        "xn--e77hia.huma.id" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            extraConfig = ''
              default_type text/plain;
              return 200 'UAE flag day!';
            '';
          };
        };

      };

    };

  };
}
