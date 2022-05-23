{ config, pkgs, lib, ... }:
{
  services.caddy = {
    enable = true;
    email = "me.caddy@huma.id";

    # Importable configurations
    config = ''
      (header) {
        # enable HSTS
        header Strict-Transport-Security max-age=31536000;
      
        # disable clients from sniffing the media type
        header X-Content-Type-Options nosniff
      	
        # clickjacking protection
        header X-Frame-Options DENY
      
        header Referrer-Policy strict-origin
        header X-XSS-Protection 1; mode=block
        header server huh?
      
        @cachedFiles {
          path *.jpg *.jpeg *.png *.gif *.ico *.css *.js *.svg
        }
      
        header @cachedFiles Cache-Control "public, max-age=31536000, must-revalidate"
      }
      
      (general) {
        encode {
          gzip 8
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
    virtualHosts."bot.huma.id".extraConfig = "respond \"beep boop\"";
    virtualHosts."buildstatusproxy.huma.id".extraConfig = ''
      handle /~humaid/*.svg {
        reverse_proxy https://builds.sr.ht {
          header_up Host {upstream_hostport}
        }
      }
      handle {
        respond "This is a private proxy for builds.sr.ht status images."
      }
    '';

    # Redirect all domains back to huma.id, preserving the path.
    virtualHosts."www.huma.id" = {
      serverAliases = [ "humaidq.ae" "www.humaidq.ae" ];
      extraConfig = "redir https://huma.id{uri} permanent";
    };
  };
}
