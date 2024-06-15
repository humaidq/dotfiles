{
  config,
  lib,
  ...
}: let
  cfg = config.sifr.caddy;
in {
  options.sifr.caddy.enable = lib.mkOption {
    description = "Enables caddy server configuration";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.enable {
    # Open ports for Caddy
    networking.firewall.allowedTCPPorts = [443 80];

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
          log {
            #format single_field common_log
            output file /var/log/access.log
          }
        }

        (cors) {
          @origin header Origin {args.0}
          header @origin Access-Control-Allow-Origin "{args.0}"
          header @origin Access-Control-Request-Method GET
        }
      '';

      # Main website configuration
      virtualHosts."huma.id".extraConfig = ''
        root * /srv/root
        file_server
        import header
        import cors huma.id
        import general
        handle_errors {
          rewrite * /{http.error.status_code}.html
          file_server
        }
      '';

      virtualHosts."*.alq.ae" = {
        extraConfig = ''
          respond "Not connected to Tailscale"
        '';
        serverAliases = ["alq.ae"];
      };
      # For serving files
      virtualHosts."f.huma.id".extraConfig = ''
        root * /srv/files
        file_server
        import header
        import cors f.huma.id
        import general
      '';

      virtualHosts."saleh.boo".extraConfig = ''
        root * /srv/saleh
        file_server
        import header
        import cors saleh.boo
        import general
      '';

      # Fun stuff
      virtualHosts."bot.huma.id".extraConfig = "respond \"beep boop\"";
      virtualHosts."car.huma.id".extraConfig = "respond \"vroom vroom\"";
      virtualHosts."xn--e77hia.huma.id".extraConfig = "respond \"UAE flag day!\"";

      # Sarim Repository
      virtualHosts."sarim.huma.id".extraConfig = ''
        root * /srv/sarim
        file_server
        basicauth * {
          sarim $2a$14$QbtiHp/b2Iaue/5At71guutf4XIeA2qANorbuI7dVTSCFli4KBfJa
        }
        header *.bundle Content-Type "application/octet-stream"
      '';

      # Redirect all domains back to huma.id, preserving the path.
      virtualHosts."www.huma.id" = {
        serverAliases = ["humaidq.ae" "www.humaidq.ae"];
        extraConfig = "redir https://huma.id{uri} permanent";
      };
    };
  };
}
