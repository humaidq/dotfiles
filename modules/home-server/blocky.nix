{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    topology.self.services.adguardhome.info = "https://adguard.alq.ae";
    services.resolved.enable = lib.mkForce false;
    networking.resolvconf.useLocalResolver = true;
    networking.firewall.allowedUDPPorts = [ 53 ];
    networking.firewall.allowedTCPPorts = [ 53 ];

    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 53;
          http = 3333;
          https = 4333;
          tls = 853;
        };
        upstreams = {
          strategy = "strict";
          groups = {
            default = [
              "tcp-tls:1.1.1.1:853"
              "tcp-tls:1.0.0.1:853"
              # Etisalat
              #"213.42.20.20"
              #"195.229.241.222"
            ];
          };
        };
        caching = {
          minTime = "6h";
          prefetching = true;
        };
        prometheus.enable = true;
        customDNS = {
          customTTL = "3h";
          rewrite.local = "alq.ae";
          mapping = {
            "alq.ae" = "100.83.164.46,192.168.1.250";
            #"cache.huma.id" = "100.83.164.46,192.168.1.250";
          };
        };
        blocking = {
          loading = {
            strategy = "fast";
            concurrency = 10;
            refreshPeriod = "3h";
          };
          blockType = "zeroIp";
          clientGroupsBlock = {
            default = [
              "hagezi"
              "steven"
              "extras"
              "ips"
            ];
          };
          denylists = {
            # Hagezi block lists: https://github.com/hagezi/dns-blocklists?tab=readme-ov-file
            hagezi = [
              # Pro List
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.txt"
              # Threat Intelligence Feeds
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.txt"
              # Gambling
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/gambling.txt"
              # Pop-up Ads
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/popupads.txt"
              # Fake Sites & Scams
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/fake.txt"

            ];

            steven = [
              # StevenBlack Hosts
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts"
            ];

            extras = [
              # DMCA abusers
              "https://paulgb.github.io/BarbBlock/blacklists/hosts-file.txt"
              # Windows telemetry
              "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
              # Smart TV telemetry
              "https://blocklistproject.github.io/Lists/smart-tv.txt"

              # Recommended by hagezi
              "https://nsfw.oisd.nl/domainswild"
            ];

            ips = [
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
            ];
          };
          allowlists = {
            general = [
              "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt"
              "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt"
              "https://blocklistproject.github.io/Lists/torrent.txt"
            ];
            custom =
              let
                customlist = pkgs.writeText "customlist" ''
                  rargb.to
                  tracker.coppersurfer.tk
                  linuxtracker.org
                  bttracker.debian.org
                  ipv4announce.sktorrent.eu
                '';
              in
              [ "${customlist}" ];
          };
        };
      };
    };

  };
}
