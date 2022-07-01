{ config, pkgs, lib, ... }:
{
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
          @cachedFiles Cache-Control "public, max-age=31536000, must-revalidate"
        }
        

        @cachedFiles {
          path *.jpg *.jpeg *.png *.gif *.ico *.css *.js *.svg
        }
      
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
    virtualHosts."f.huma.id".extraConfig = ''
      root * /srv/files
      file_server
      import header
      import cors f.huma.id
      import general
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

    # Redirect all domains back to huma.id without perserving path.
    virtualHosts."live.humaidq.ae" = {
      serverAliases = [
        "csldg.humaidq.ae"
        "maps.humaidq.ae"
        "morse.humaidq.ae"
        "areweherdimmuneyet.humaidq.ae"
        "areweherdimmuneyet.huma.id"
        "awhiy.humaidq.ae"
        "notes-testing.humaidq.ae"
        "hw-status.humaidq.ae"
        "notebook.humaidq.ae"
        "covid.huma.id"
        "maps.huma.id"
      ];
      extraConfig = "redir https://huma.id permanent";
    };
  };
}
