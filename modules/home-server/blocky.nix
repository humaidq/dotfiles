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
              "tcp-tls:family.cloudflare-dns.com"
              # Etisalat
              #"213.42.20.20"
              #"195.229.241.222"
            ];
          };
        };
        bootstrapDns = [
          {
            upstream = "tcp-tls:family.cloudflare-dns.com";
            ips = [
              "1.1.1.3"
              "1.0.0.3"
            ];
          }
        ];
        caching = {
          minTime = "6h";
          prefetching = true;
        };
        prometheus.enable = true;
        customDNS = {
          rewrite = {
            #local = "alq.ae"; # resolves everything to alq.ae

            # Safe search
            "google.*" = "forcesafesearch.google.com";
            "www.google.*" = "forcesafesearch.google.com";
            "google.com" = "forcesafesearch.google.com";
            "www.google.com" = "forcesafesearch.google.com";

            "www.youtube.com" = "restrict.youtube.com";
            "m.youtube.com" = "restrict.youtube.com";
            "youtubei.googleapis.com" = "restrict.youtube.com";
            "youtube.googleapis.com" = "restrict.youtube.com";
            "www.youtube-nocookie.com" = "restrict.youtube.com";

            "www.bing.com" = "strict.bing.com";
            "duckduckgo.com" = "strict.duckduckgo.com";
            "www.ecosia.org" = "strict-safe-search.ecosia.org";
          };
          mapping = {
            "www.google.com" = "216.239.38.120";
            "www.google.ae" = "216.239.38.120";
            "www.google.co.uk" = "216.239.38.120";

            "www.youtube.com" = "216.239.38.119";
            "m.youtube.com" = "216.239.38.119";
            "youtubei.googleapis.com" = "216.239.38.119";
            "youtube.googleapis.com" = "216.239.38.119";
            "www.youtube-nocookie.com" = "216.239.38.119";

            # way to test
            "test.huma.id" = "1.1.1.1";
            "alq.ae" = "10.10.0.12,192.168.1.250";

            # Not comprehensive but works
            "oreamnos" = "10.10.0.12";
            "duisk" = "10.10.0.13";
            "lighthouse" = "10.10.0.10";

            "cache.huma.id" = "10.10.0.12,192.168.1.250";
            # Fix TII sites
            "jira.tii.ae" = "10.151.12.77";
            "confluence.tii.ae" = "10.151.12.79";
          };
        };
        blocking = {
          loading = {
            strategy = "fast";
            concurrency = 10;
            refreshPeriod = "6h";
          };
          blockType = "zeroIp";
          clientGroupsBlock = {
            default = [
              "general"
              "steven"
              "extras"
              "ips"
              "ut1"
              "custom"
            ];
          };
          denylists = {
            # Hagezi block lists: https://github.com/hagezi/dns-blocklists?tab=readme-ov-file
            general = [
              # Pro List
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.txt"
              # Threat Intelligence Feeds
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"
              # Gambling
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/gambling.txt"
              # Pop-up Ads
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/popupads.txt"
              # Fake Sites & Scams
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/fake.txt"
              # Bypass
              #"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/doh-vpn-proxy-bypass.txt"
              #"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/ips/doh.txt"
              # No safe search
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nosafesearch.txt"
              # DynDNS sites
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/dyndns-onlydomains.txt"
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
              "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/native.xiaomi.txt"

              # Recommended by hagezi
              "https://nsfw.oisd.nl/domainswild"

              # Classroom Monitoring
              "https://raw.githubusercontent.com/hapara-fail/blocklist/main/blocklist.txt"

              # Sefinek Block Lists
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus.txt"
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus2.txt"
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/anime/main.txt"
            ];

            # Old list but may fill some gaps
            ut1 = [
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/astrology/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/agressif/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/dating/domains"
              #"https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/doh/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/sect/domains"
            ];

            ips = [
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
            ];

            custom = [
              "${./custom-blocklist.txt}"
            ];
          };
          allowlists = {
            general =
              let
                customlist = pkgs.writeText "blocky-custom-allowlist" ''
                  rargb.to
                  tracker.coppersurfer.tk
                  linuxtracker.org
                  bttracker.debian.org
                  ipv4announce.sktorrent.eu
                  bittorrent-tracker.e-n-c-r-y-p-t.net
                  tracker.ipv6tracker.org
                  seeders-paradise.org
                  www.torrentsnipe.info
                  highteahop.top
                  therarbg.to
                  kickass.ws
                  alak.bar
                  linuxtracker.org
                '';
              in
              [
                "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt"
                "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt"
                "https://blocklistproject.github.io/Lists/torrent.txt"
                "${customlist}"
              ];
          };
        };
      };
    };

  };
}
