{
  pkgs,
  inputs,
  ...
}:
let
  humaid-site = inputs.humaid-site.packages.${pkgs.system}.default;
in
{
  config = {
    # Open ports for Caddy
    networking.firewall.allowedTCPPorts = [
      443
      80
    ];

    # Extra hardening
    systemd.services.caddy.serviceConfig = {
      # Upstream already sets NoNewPrivileges, PrivateDevices, ProtectHome
      ProtectSystem = "strict";
      PrivateTmp = "yes";
    };

    services.caddy = {
      enable = true;
      email = "me.caddy@huma.id";

      # Importable configurations
      extraConfig = ''
        (header) {
           header {
            # enable HSTS
            Strict-Transport-Security max-age=31536000;

            # disable clients from sniffing the media type
            X-Content-Type-Options nosniff

            # clickjacking protection
            X-Frame-Options DENY


            # disable FLOC
            Permissions-Policy interest-cohort=()

            Referrer-Policy strict-origin
            X-XSS-Protection 1; mode=block
            server huh?
            @staticFiles Cache-Control "public, max-age=31536000"
          }

          @staticFiles {
            path *.jpg *.jpeg *.png *.gif *.ico *.css *.js *.svg *.webp
          }

        }

        (general) {
          encode {
            zstd
          }
          #log {
          #  #format single_field common_log
          #  output file /var/log/access.log
          #}
        }

        (cors) {
          @origin header Origin {args.0}
          header @origin Access-Control-Allow-Origin "{args.0}"
          header @origin Access-Control-Request-Method GET
        }
      '';

      # Main website configuration
      virtualHosts = {
        "huma.id".extraConfig = ''
          root * ${humaid-site}
          file_server
          import header
          import cors huma.id
          import general
          handle_errors {
            rewrite * /{http.error.status_code}.html
            file_server
          }
        '';

        "*.alq.ae" = {
          extraConfig = ''
            root * ${./sifr0-error}
            file_server
            import header
            import general
            handle_errors {
              file_server
              rewrite * /
            }
          '';
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
          ];
        };
        # For serving files
        "f.huma.id".extraConfig = ''
          root * /srv/files
          file_server
          import header
          import cors f.huma.id
          import general
        '';

        # Fun stuff
        "bot.huma.id".extraConfig = "respond \"beep boop\"";
        "car.huma.id".extraConfig = "respond \"vroom vroom\"";
        "xn--e77hia.huma.id".extraConfig = "respond \"UAE flag day!\"";

        # Sarim Repository
        "sarim.huma.id".extraConfig = ''
          root * /srv/sarim
          file_server
          basicauth * {
            sarim $2a$14$QbtiHp/b2Iaue/5At71guutf4XIeA2qANorbuI7dVTSCFli4KBfJa
          }
          header *.bundle Content-Type "application/octet-stream"
        '';

        "cache.huma.id".extraConfig = ''
          @cachepage {
            path / *.jpeg
          }
          handle @cachepage {
            root * ${./cache-page}
            file_server
          }
          reverse_proxy 10.10.0.12:5000
        '';

        "dns.huma.id".extraConfig = ''
          handle / {
            redir https://lighthouse.huma.id permanent
          }
          handle /dns-query* {
            reverse_proxy 127.0.0.1:3333
          }
        '';

        "sdr.huma.id".extraConfig = ''
          reverse_proxy http://sdr.alq.ae {
            header_up Host sdr.alq.ae
          }
        '';

        # Redirect all domains back to huma.id, preserving the path.
        "www.huma.id" = {
          serverAliases = [
            "humaidq.ae"
            "www.humaidq.ae"
          ];
          extraConfig = "redir https://huma.id{uri} permanent";
        };
      };
    };
  };
}
