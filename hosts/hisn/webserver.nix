{
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
  # error-pages without proxy_intercept_errors, for the PoW-gated locations.
  #
  # Those locations carry `error_page 401 = /.groundwave/pow/challenge`, and
  # proxy_intercept_errors is all-or-nothing: it routes every upstream status
  # that has an error_page defined through that page. Turning it on there would
  # mean an application's own 401 — a rejected login, say — is answered with
  # the proof-of-work challenge instead of reaching the browser, which the
  # frontend has no way to tell apart from being logged out.
  #
  # Dropping it costs nothing for the case that actually matters. nginx applies
  # error_page to the 502 and 504 it generates itself regardless of this
  # setting, and upstream-unreachable — service down, oreamnos down, a missing
  # nebula rule — is precisely that case.
  error-pages-no-intercept = ''
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
  # Same markup as the generic pages, but the sub-text is written for the
  # people standing at the printer rather than for someone debugging a proxy.
  # Only mbzuai-cs-printer.huma.id uses this.
  #
  # 504 gets the booth wording too, not just 502, because the two upstream
  # failures are indistinguishable from the booth: anoa refusing the port gives
  # 502, anoa being off the mesh gives 504 (see the vhost below), and neither is
  # something the person waiting for a printout can act on differently.
  printer-error-pages-loc = ''
    location = /_error/502.html {
      internal;
      default_type text/html;
      alias ${./error-pages/502-printer.html};
    }
    location = /_error/504.html {
      internal;
      default_type text/html;
      alias ${./error-pages/504-printer.html};
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
    # Only dedicated virtual hosts may opt in to Groundwave's PoW proxy API.
    proxy_set_header X-Groundwave-PoW-Proxy "";
    proxy_set_header X-Original-URI "";
    proxy_set_header X-Original-Method "";

    ${proxyHeaders}
  '';
  groundwavePowProxyHeaders = ''
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For "";
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
    proxy_set_header X-Groundwave-PoW-Proxy "1";
    proxy_set_header X-Original-URI $groundwave_pow_original_uri;
    proxy_set_header X-Original-Method $groundwave_pow_original_method;
  '';
  groundwavePowLocations =
    {
      applicationUpstream,
      # nginx directives for the gated "/" location, replacing the http-level
      # proxy defaults it would otherwise repeat. Parameterised rather than
      # shared because proxy_set_header at location level replaces the
      # inherited set wholesale instead of extending it, so a vhost that needs
      # one header different has to restate all of them, and because a second
      # Host or a second proxy_http_version in the same location is a config
      # error rather than a last-one-wins override.
      applicationProxyConfig ? proxyDefaults,
      # Passing a WebSocket through the gate needs this rather than the
      # directives spelled out in applicationProxyConfig: the nixpkgs module
      # emits the Upgrade/Connection pair *before* extraConfig, so anything
      # here that also sets Connection or proxy_http_version either overwrites
      # the upgrade or refuses to start. Leave both out of
      # applicationProxyConfig and set this instead.
      proxyWebsockets ? false,
    }:
    let
      internalGroundwaveLocation = path: {
        proxyPass = "${upstream}${path}";
        extraConfig = ''
          internal;
          proxy_method GET;
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
          ${groundwavePowProxyHeaders}
        '';
      };
      publicGroundwaveLocation = path: {
        proxyPass = "${upstream}${path}";
        extraConfig = ''
          ${groundwavePowProxyHeaders}
          ${proxyHeaders}
        '';
      };
    in
    {
      "= /.groundwave/pow/check" = internalGroundwaveLocation "/.groundwave/pow/check";
      "= /.groundwave/pow/challenge" = internalGroundwaveLocation "/.groundwave/pow/challenge";
      "= /.groundwave/pow/verify" = publicGroundwaveLocation "/.groundwave/pow/verify";
      "= /.groundwave/pow/pow.js" = publicGroundwaveLocation "/.groundwave/pow/pow.js";
      "= /.groundwave/pow/pow-worker.js" = publicGroundwaveLocation "/.groundwave/pow/pow-worker.js";
      "^~ /.groundwave/pow/" = {
        extraConfig = ''
          return 404;
        '';
      };
      "/" = {
        inherit proxyWebsockets;
        proxyPass = applicationUpstream;
        extraConfig = ''
          ${applicationProxyConfig}
          ${error-pages-no-intercept}

          proxy_set_header X-Groundwave-PoW-Proxy "";
          proxy_set_header X-Original-URI "";
          proxy_set_header X-Original-Method "";

          # Capture these on the main request. The auth subrequest is forced
          # to GET upstream, but policy still needs the browser's real method.
          set $groundwave_pow_original_uri $request_uri;
          set $groundwave_pow_original_method $request_method;
          auth_request /.groundwave/pow/check;
          # Only GET/HEAD checks return 401. Mutations return 403 and are
          # never redirected or replayed after solving a challenge.
          error_page 401 = /.groundwave/pow/challenge;
        '';
      };
    };
  # m.huma.id is Matomo, and it is a separate origin from this one, so 'self'
  # does not cover it. Three directives need it, because the tracker touches
  # the network three different ways: script-src to load /m.js at all, img-src
  # because the default beacon is an Image() GET, and connect-src for the
  # sendBeacon and XHR paths it switches to for large payloads or an explicit
  # POST. Miss any one and tracking fails in a way that only shows up as a
  # console violation on some pageviews.
  #
  # Deliberately not widened past those three, and named rather than wildcarded:
  # nothing about analytics needs to relax style-src, font-src or object-src.
  matomoOrigin = "https://m.huma.id";
  humaidCsp = "default-src 'self'; script-src 'self' 'unsafe-inline' ${matomoOrigin}; style-src 'self' 'unsafe-inline'; img-src 'self' data: ${matomoOrigin}; font-src 'self' data:; connect-src 'self' ${matomoOrigin}; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'";
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

        # The landing page lives under modules/home-server because oreamnos
        # serves the identical thing on its own copy of this vhost — clients
        # inside the mesh resolve cache.huma.id to 10.10.0.12 from nebula's
        # host entries and never touch this host. Two copies of the page drift;
        # one copy referenced from both does not. It sits with the home server
        # rather than here because that is where harmonia actually runs, and
        # this vhost is a public front for it.
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
              root = "${../../modules/home-server/cache-page}";
              extraConfig = ''
                index index.html;
                try_files /index.html =404;
              '';
            };
            "~* \\.jpeg$" = {
              root = "${../../modules/home-server/cache-page}";
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
        # /m and /m.js are aliases for /matomo.php and /matomo.js. Both of the
        # real names are on EasyPrivacy, so a visitor running any of the usual
        # blocklists loses the beacon — and, because the snippet fetches the
        # tracker itself from this host, loses tracking entirely rather than
        # degrading. The host is a subdomain of a domain nobody is filtering, so
        # the paths are the whole of what gets matched, and renaming them at the
        # edge is enough. Aliased rather than moved: Matomo's own UI, its update
        # checks and matomo-archive-processing all still address the real names.
        #
        # proxy_pass with a URI replaces the matched part of the request, and
        # nginx appends the query string on its own as long as that URI has no
        # `?` of its own — which matters here, since a tracking beacon is
        # entirely query string.
        #
        # No basic auth. It was only ever there to hold the door shut over the
        # install window, because Matomo has no way to seed a superuser other
        # than the wizard and until that is finished the first caller to reach
        # it owns the instance. The superuser now exists, so Matomo's own login
        # is the thing guarding the UI.
        "m.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';
          locations = {
            "/" = {
              proxyPass = "http://10.10.0.12";
              extraConfig = error-pages;
            };
            "= /m" = {
              proxyPass = "http://10.10.0.12/matomo.php";
              extraConfig = error-pages;
            };
            "= /m.js" = {
              proxyPass = "http://10.10.0.12/matomo.js";
              extraConfig = error-pages;
            };
          };
        };

        # Served by Caddy on the old lighthouse host, which existed for this
        # one static page and nothing else. Moved onto nginx rather than
        # carried over as a second web server: the two would have fought over
        # 443, and a second ACME client on the same box is a second set of
        # certificates to reason about when one of them stops renewing.
        #
        # The name stays `lighthouse.huma.id` even though the host is now
        # `hisn`. It is a published name, and renaming it is a DNS record and a
        # certificate — both unrelated to moving the machine.
        #
        # No add_header block: with none set here the server inherits the
        # http-level security-headers, which is what is wanted for a page with
        # no proxy behind it.
        "lighthouse.huma.id" = {
          enableACME = true;
          forceSSL = true;
          root = ./lighthouse-page;
        };

        # dns.huma.id was here and is deliberately gone. It published this
        # host's blocky as DoT on 853 and as DoH under /dns-query, for use off
        # the LAN. Both are removed: an ISP resolver is the upstream the
        # routers now use (see modules/router/blocky-common.nix) and it answers
        # only its own subscribers, so a resolver on a VPS in another network
        # could not share their configuration even if it were kept.
        #
        # Nothing replaces it. Off-LAN resolution is the router over the mesh
        # (10.10.0.16), which is what lighthouse-page has always pointed at.
        # The `dns.huma.id` DNS record still exists in the huma.id zone and is
        # now unserved — delete it there if it should stop resolving.

        # Proxies to a service on anoa, not oreamnos — the only vhost here that
        # does. anoa is a laptop, so this name is up only when that machine is
        # on the mesh; the 502 page is the expected answer the rest of the
        # time, which is why error-pages-loc is here rather than left off the
        # way the static vhosts do.
        #
        # anoa is addressed by overlay IP because it has no entry in
        # nebula.nix's hostMappings, unlike oreamnos. The matching inbound rule
        # on anoa names `hisn` and port 8585; without it this returns 502 even
        # when the laptop is up, since nebula's own firewall drops the
        # connection before nginx there ever sees it.
        "mbzuai-cs-printer.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${printer-error-pages-loc}
            client_max_body_size 512M;
          '';
          locations."/" = {
            proxyPass = "http://10.10.0.50:8585";
            extraConfig = ''
              ${proxyHeaders}

              # The http-block default is 60s, which is right for oreamnos but
              # wrong here. The two ways this upstream fails look nothing alike:
              # anoa up with 8585 closed gets an RST from its kernel and answers
              # instantly, but anoa off the mesh has no tunnel at all, so nebula
              # drops the SYN with no RST and no ICMP unreachable and nginx sits
              # there retransmitting for the full timeout. That is the common
              # case — anoa is a laptop — and a minute of blank tab is worse than
              # no page at all for someone standing at the booth. 3s is far more
              # than a handshake across the mesh needs.
              proxy_connect_timeout 3s;
            '';
          };
        };

        "admin.fleeti.ae" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = groundwavePowLocations { applicationUpstream = "http://10.10.0.12:4231"; };
        };

        # Same PoW treatment as admin.fleeti.ae, and for the same reason: the
        # application has its own login, but the sign-up and submission
        # endpoints are cheap to hammer and the evaluator spends a container
        # per submission. The gate is in front of everything, so the SPA's own
        # API calls ride the cookie the browser already solved for.
        "tii-debug-platform.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = groundwavePowLocations { applicationUpstream = "http://10.10.0.12:4233"; };
        };
        # Same PoW gate again, over a WebSocket application this time. The
        # receiver has no login of its own worth the name and every listener
        # costs it one of twelve channels, so a crawler that opens the page is
        # not a wasted request but a denied seat; the gate turns that into work
        # nobody automates for free.
        #
        # The audio, waterfall and extension sockets all live under "/" and are
        # opened by the page after it has already solved a challenge, so they
        # ride the cookie the browser is holding — same-origin WebSocket
        # handshakes carry cookies, and the handshake is a GET, which is the
        # only method the check answers 401 to. auth_request runs on the
        # handshake, before the upgrade, and does not sit in the socket's path
        # afterwards.
        #
        # Non-browser clients (kiwirecorder and friends) cannot solve the
        # challenge and lose access. The hourly noise sweep is not one of them:
        # sifr.personal.sdrNoise talks to the receiver's LAN address from
        # oreamnos and never resolves this name.
        "sdr.huma.id" = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            ${error-pages-loc}
          '';

          locations = groundwavePowLocations {
            applicationUpstream = "http://10.10.0.12";
            proxyWebsockets = true;
            # Host is rewritten because the far end of the mesh hop is
            # oreamnos's nginx, which selects the receiver by server_name.
            # No Connection or proxy_http_version here on purpose -- see
            # proxyWebsockets above.
            applicationProxyConfig = ''
              proxy_set_header Host sdr.alq.ae;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For "";
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_set_header X-Forwarded-Server $hostname;
            '';
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
