_: {
  config = {
    systemd.services.blocky.serviceConfig = {
      SupplementaryGroups = [ "caddy" ];
    };

    networking.firewall.allowedTCPPorts = [
      853
    ];
    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 53;
          http = 3333;
          https = 4333;
          tls = 853;
        };
        tls = {
          certFile = "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.crt";
          keyFile = "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/dns.huma.id/dns.huma.id.key";
        };
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
