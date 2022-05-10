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
    '';

    # Redirect all domains back to huma.id, preserving the path.
    virtualHosts."www.huma.id" = {
      serverAliases = [ "humaidq.ae" "www.humaidq.ae" ];
      extraConfig = "redir https://huma.id{uri} permanent";
    };
  };
}
