{ lib, ... }:
{
  config = {
    users.groups.blocky = { };
    users.users.blocky = {
      isSystemUser = true;
      group = "blocky";
      extraGroups = [ "nginx" ];
    };
    systemd.services.blocky.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "blocky";
      Group = "blocky";
      SupplementaryGroups = [ "nginx" ];
    };
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
        certFile = "/var/lib/acme/dns.huma.id/cert.pem";
        keyFile = "/var/lib/acme/dns.huma.id/key.pem";
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
