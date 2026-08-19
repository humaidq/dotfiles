{
  config,
  pkgs,
  inputs,
  vars,
  ...
}:
let
  humaid-site = inputs.humaid-site.packages.${pkgs.stdenv.hostPlatform.system}.default;
  security-headers = ''
    add_header Strict-Transport-Security "max-age=31536000" always;
    # Enable CSP for your services.
    #add_header Content-Security-Policy "script-src 'self'; object-src 'none'; base-uri 'none';" always;
    add_header X-Content-Type-Options "nosniff" always;
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
  upstream = "http://10.10.0.12:4232";
  groundwaveHeaders = ''
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Referrer-Policy "strict-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
  '';
  proxyDefaults = ''
    proxy_redirect off;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  proxyHeaders = ''
    ${error-pages}

    proxy_set_header X-Request-ID $request_id;

    # general
    limit_req zone=general burst=30 nodelay;

    # for any post
    limit_req zone=post burst=2 nodelay;
    ${groundwaveHeaders}
  '';
  groundwaveProxyHeaders = ''
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For "";
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;

    ${proxyHeaders}
  '';
  humaidCsp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'";
  humaidHeaders = ''
    add_header Content-Security-Policy "${humaidCsp}" always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Referrer-Policy "strict-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
  '';
  groundwaveRootLocations = {
    "= /pow" = {
      proxyPass = "${upstream}/pow";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /pow/verify" = {
      proxyPass = "${upstream}/pow/verify";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /connectivity" = {
      proxyPass = "${upstream}/connectivity";
      extraConfig = groundwaveProxyHeaders;
    };
    # Groundwave serves its whole static tree (embedded src/static) at the
    # upstream root: stylesheets under /css/, the Vite/React bundle under /app/,
    # and the PDF.js viewer under /pdfjs/. These must reach the upstream root
    # unrewritten, so they are ^~ prefixes to outrank the f.huma.id "/" -> /f/
    # catch-all rewrite. proxyPass without a URI passes the request path as-is.
    "^~ /css/" = {
      proxyPass = upstream;
      extraConfig = groundwaveProxyHeaders;
    };
    "^~ /app/" = {
      proxyPass = upstream;
      extraConfig = groundwaveProxyHeaders;
    };
    "^~ /pdfjs/" = {
      proxyPass = upstream;
      extraConfig = groundwaveProxyHeaders;
    };
    "= /normalize-8.0.1.min.css" = {
      proxyPass = "${upstream}/normalize-8.0.1.min.css";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /webauthn.js" = {
      proxyPass = "${upstream}/webauthn.js";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /manifest.json" = {
      proxyPass = "${upstream}/manifest.json";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /icon-64.png" = {
      proxyPass = "${upstream}/icon-64.png";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /icon-128.png" = {
      proxyPass = "${upstream}/icon-128.png";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /icon-512.png" = {
      proxyPass = "${upstream}/icon-512.png";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /pow.js" = {
      proxyPass = "${upstream}/pow.js";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /pow-worker.js" = {
      proxyPass = "${upstream}/pow-worker.js";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /sw.js" = {
      proxyPass = "${upstream}/sw.js";
      extraConfig = groundwaveProxyHeaders;
    };
    "= /robots.txt" = {
      proxyPass = "${upstream}/robots.txt";
      extraConfig = groundwaveProxyHeaders;
    };
  };
in
{
  config = {
    nixpkgs.overlays = [
      inputs.fleeti.overlays.default
    ];
    networking.firewall.allowedTCPPorts = [
      443
      80
    ];

    # sarim.huma.id serves a 2GB tree that is not in this repo and has no other
    # source than the machine it is being migrated off. Declaring the directory
    # — not its contents — is the only way that dependency is visible to anyone
    # reading this file, and it means the copy lands without needing root on
    # this end. Ownership matches what it had on duisk, where the tree is
    # readable by the primary user rather than by nginx alone.
    systemd.tmpfiles.rules = [
      "d /srv 0755 ${vars.user} root -"
      "d /srv/sarim 0755 ${vars.user} users -"
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = "acme@huma.id";
    };

    # Fronts the Matomo UI. Kept in sops rather than inline the way
    # sarim.huma.id's is, because this one guards an admin interface and this
    # repository is public.
    sops.secrets."web/matomo-htpasswd" = {
      sopsFile = ../../secrets/hisn.yaml;
      owner = "nginx";
      mode = "640";
    };

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = false;
      recommendedOptimisation = true;
      recommendedBrotliSettings = true;

      appendHttpConfig = ''
        ${proxyDefaults}

        ${security-headers}

        map $server_name $limit_conn_key {
          default $binary_remote_addr;
          cache.huma.id "";
          dns.huma.id "";
          sdr.huma.id "";
        }

        map $request_method $limit_post {
          default "";
          POST    $binary_remote_addr;
        }

        # Connection limit
        limit_conn_zone $limit_conn_key zone=all_hosts:10m;
        limit_conn all_hosts 15;
        limit_conn_status 429;

        # Rate limit
        limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
        limit_req_zone $binary_remote_addr zone=expensive:10m rate=1r/s;
        limit_req_zone $limit_post zone=post:10m rate=2r/s;
        limit_req_status 429;
      '';

      virtualHosts = {
        "huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
            ${humaidHeaders}
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
          locations = groundwaveRootLocations // {
            "= /" = {
              proxyPass = "${upstream}/oqrs";
              extraConfig = groundwaveProxyHeaders;
            };
            "= /qrz" = {
              proxyPass = "${upstream}/qrz";
              extraConfig = groundwaveProxyHeaders;
            };
            "= /oqrs" = {
              proxyPass = "${upstream}/oqrs";
              extraConfig = groundwaveProxyHeaders;
            };
            "^~ /oqrs/" = {
              proxyPass = upstream;
              extraConfig = groundwaveProxyHeaders;
            };
            "^~ /qrz/" = {
              proxyPass = upstream;
              extraConfig = groundwaveProxyHeaders;
            };
            "/" = {
              proxyPass = upstream;
              extraConfig = groundwaveProxyHeaders;
            };
          };
        };

        "f.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations = groundwaveRootLocations // {
            "^~ /f/" = {
              proxyPass = upstream;
              extraConfig = groundwaveProxyHeaders;
            };
            "/" = {
              proxyPass = upstream;
              extraConfig = ''
                ${groundwaveProxyHeaders}
                rewrite ^/(.*)$ /f/$1 break;
              '';
            };
          };
        };

        "g.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
            client_max_body_size 50000M;
          '';
          locations."/" = {
            proxyPass = upstream;
            extraConfig = groundwaveProxyHeaders;
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
              extraConfig = ''
                index index.html;
                try_files /index.html =404;
              '';
            };
            "~* \\.jpeg$" = {
              root = "${./cache-page}";
            };
          };
        };

        # Matomo, which runs on oreamnos. Unlike cache.huma.id this proxies to
        # that host's nginx on port 80 rather than to a service port, because
        # Matomo is PHP behind php-fpm and its nginx vhost is the application —
        # the fastcgi socket is not something that can be reached across the
        # mesh. The vhost there is addSSL, not forceSSL, precisely so this hop
        # is not answered with a redirect back to this machine.
        #
        # No proxy_set_header of its own in the location: error-pages sets only
        # proxy_intercept_errors and error_page, neither of which triggers
        # nginx's rule that a location defining any proxy_set_header discards
        # every one inherited from the http block. So proxyDefaults still
        # applies, and X-Forwarded-For carries the real client address — which
        # Matomo needs for geolocation, and which is why the header is passed
        # through here rather than blanked the way the internal vhosts do.
        #
        # basicAuthFile covers the whole vhost, tracking endpoints included.
        # That is deliberate but it is not a permanent arrangement: while it is
        # on, /matomo.php and /matomo.js answer 401, so no site can actually be
        # tracked through this name. It exists to hold the door shut over the
        # install window — Matomo has no way to seed a superuser other than the
        # wizard, so before that wizard is finished the first caller to reach it
        # owns the instance. Take it off, or narrow it to everything but the two
        # tracking paths, once the superuser exists.
        "m.huma.id" = {
          enableACME = true;
          forceSSL = true;
          basicAuthFile = config.sops.secrets."web/matomo-htpasswd".path;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations."/" = {
            proxyPass = "http://10.10.0.12";
            extraConfig = error-pages;
          };
        };

        # Served by Caddy on the old lighthouse host, which existed for this
        # one static page and nothing else. Moved onto nginx rather than
        # carried over as a second web server: the two would have fought over
        # 443, and a second ACME client on the same box is a second set of
        # certificates to reason about when one of them stops renewing.
        #
        # The name stays `lighthouse.huma.id` even though the host is now
        # `hisn`. It is a published name that dns.huma.id redirects to below,
        # and renaming it is a DNS record, a certificate and a redirect — all
        # unrelated to moving the machine.
        #
        # No add_header block: with none set here the server inherits the
        # http-level security-headers, which is what is wanted for a page with
        # no proxy behind it.
        "lighthouse.huma.id" = {
          enableACME = true;
          forceSSL = true;
          root = ./lighthouse-page;
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
                proxy_set_header X-Forwarded-For "";
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

        "admin.fleeti.ae" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = {
            "/" = {
              proxyPass = "http://10.10.0.12:4231";
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
              proxyPass = "http://10.10.0.12";
              recommendedProxySettings = false;
              proxyWebsockets = true;

              extraConfig = ''
                ${error-pages}

                proxy_set_header Host sdr.alq.ae;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For "";
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Host $host;
                proxy_set_header X-Forwarded-Server $hostname;
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
            "vault.alq.ae"
            "git.alq.ae"
            "grafana.alq.ae"
            "cache.alq.ae"
            "pdf.alq.ae"
            "dav.alq.ae"
            "webdav.alq.ae"
            "img.alq.ae"
            "ai.alq.ae"
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

        "fleeti.ae" = {
          enableACME = true;
          forceSSL = true;
          root = pkgs.fleeti-docs;
        };

        "www.fleeti.ae" = {
          enableACME = true;
          forceSSL = true;
          globalRedirect = "fleeti.ae";
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
