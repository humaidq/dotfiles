_: {
  config = {
    services.blocky = {
      enable = true;
      settings = {
        ports = {
          dns = 1153;
          http = 3333;
          https = 4333;
          tls = 853;
        };
        upstreams = {
          strategy = "strict";
          groups = {
            default = [
              "tcp-tls:family.cloudflare-dns.com"
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
          maxTime = "24h";
          prefetchExpires = "24h";
          prefetching = true;
        };
        prometheus.enable = true;
        customDNS = {
          rewrite = { };
          mapping = {
            "test.huma.id" = "1.1.1.1";
            "alq.ae" = "10.10.0.12,192.168.1.250";

            "oreamnos" = "10.10.0.12";
            "duisk" = "10.10.0.13";
            "lighthouse" = "10.10.0.10";

            "cache.huma.id" = "10.10.0.12,192.168.1.250";
            "g.huma.id" = "10.10.0.12,192.168.1.250";

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
            general = [
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.plus.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/gambling.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/popupads.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/fake.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/dyndns.txt"
            ];

            steven = [
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts"
            ];

            extras = [
              "https://paulgb.github.io/BarbBlock/blacklists/hosts-file.txt"
              "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
              "https://blocklistproject.github.io/Lists/smart-tv.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.xiaomi.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.oppo-realme.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.vivo.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.roku.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.lgwebos.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.tiktok.extended.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.samsung.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/domains/native.winoffice.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.huawei.txt"
              "https://nsfw.oisd.nl/domainswild"
              "https://raw.githubusercontent.com/hapara-fail/blocklist/main/blocklist.txt"
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus.txt"
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus2.txt"
              "https://blocklist.sefinek.net/generated/v1/0.0.0.0/anime/main.txt"
              "https://v.firebog.net/hosts/static/w3kbl.txt"
              "https://v.firebog.net/hosts/neohostsbasic.txt"
              "https://raw.githubusercontent.com/RooneyMcNibNug/pihole-stuff/master/SNAFU.txt"
              "https://raw.githubusercontent.com/fmhy/FMHYFilterlist/main/filterlist-wildcard-domains.txt"
            ];

            ut1 = [
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/astrology/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/agressif/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/dating/domains"
              "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/sect/domains"
            ];

            ips = [
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
            ];

            custom = [
              "${../../modules/home-server/custom-blocklist.txt}"
            ];
          };
          allowlists = {
            general = [
              "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt"
              "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt"
              "https://blocklistproject.github.io/Lists/torrent.txt"
              "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/anti.piracy.txt"
              "${../../modules/home-server/custom-whitelist.txt}"
            ];
          };
        };
      };
    };
  };
}
