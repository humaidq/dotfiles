{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
  tls = {
    forceSSL = true;
  };
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
    sops.secrets."web/fullchain" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nginx";
      mode = "600";
    };
    sops.secrets."web/privkey" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nginx";
      mode = "600";
    };

    security.acme.acceptTerms = true;
    security.acme.defaults = {
      email = "local@alq.ae";
      server = "https://alq.ae:8443/acme/acme/directory";
    };

    services.nginx = {
      enable = true;
      recommendedZstdSettings = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      virtualHosts = lib.mkMerge [
        #(mkRP "" "8082")
        (mkRP "cache" "5000")
        (mkRP "dns" "3333")
        (mkRP "vault" "8222")
        (mkRP "grafana" "3000")
        (mkRP "deluge" "8112")
        (mkRP "radarr" "7878")
        (mkRP "sonarr" "8989")
        (mkRP "prowlarr" "9696")
        (mkRP "catalogue" (builtins.toString config.services.jellyseerr.port))
        (mkRP "tv" "8096")
        (mkRP "pdf" "8084")
        (mkRP "git" "3939")
        (mkRP "dav" "5232")
        (mkRP "webdav" "8477")

        {
          "alq.ae" = {
            enableACME = true;
            inherit (tls) forceSSL;
            locations."/" = {
              root = ./homepage;
            };
          };
          "sdr.alq.ae" = {
            enableACME = true;
            locations."/" = {
              proxyPass = "http://192.168.1.164:8073";
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
              proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;

              # enable websockets: http://nginx.org/en/docs/http/websocket.html
              proxy_http_version 1.1;
              proxy_set_header   Upgrade    $http_upgrade;
              proxy_set_header   Connection "upgrade";
              proxy_redirect     off;

              # set timeout
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
              send_timeout       600s;
            '';
            locations."/" = {
              proxyPass = "http://127.0.0.1:3011";
            };
          };
        }
      ];
    };
  };
}
