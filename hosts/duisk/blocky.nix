{ lib, ... }:
{
  config = {
    users.groups.blocky = { };
    users.users.blocky = {
      isSystemUser = true;
      group = "blocky";
      extraGroups = [ "caddy" ];
    };
    systemd.services.blocky.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "blocky";
      Group = "blocky";
      SupplementaryGroups = [ "caddy" ];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/caddy 0750 caddy caddy - -"
      "d /var/lib/caddy/.local 0750 caddy caddy - -"
      "d /var/lib/caddy/.local/share 0750 caddy caddy - -"
      "d /var/lib/caddy/.local/share/caddy 0750 caddy caddy - -"
      "d /var/lib/caddy/.local/share/caddy/certificates 0750 caddy caddy - -"
      "d /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory 0750 caddy caddy - -"
      "d /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id 0750 caddy caddy - -"
      "f /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.crt 0640 caddy caddy - -"
      "f /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.key 0640 caddy caddy - -"
    ];
    systemd.services.caddy.serviceConfig.UMask = "0027";
    networking.firewall.allowedTCPPorts = [
      853
    ];
    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 1153;
          http = 3333;
          https = 4333;
          tls = 853;
        };
        certFile = "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.crt";
        keyFile = "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.key";
        upstreams = {
          strategy = "strict";
          groups = {
            default = [
              "10.10.0.12"
            ];
          };
        };
        caching = {
          minTime = "6h";
          prefetching = true;
        };
      };
    };
  };
}
