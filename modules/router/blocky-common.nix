{
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
  # archive.today and its mirrors are all one service, and the default upstream
  # refuses to resolve any of them: 1.1.1.3 answers 0.0.0.0, and so does
  # 1.1.1.2, so this is Cloudflare's classification rather than the family
  # filter specifically. The names are already in custom-whitelist.txt and
  # blocky is not blocking them — it reports response_type=RESOLVED and passes
  # the upstream's 0.0.0.0 straight through — so no blocklist change can fix
  # it. Send just these zones to a resolver that answers them instead.
  #
  # Quad9 rather than 1.1.1.1, which returns an empty answer for these: the
  # archive.today operator has long declined to serve Cloudflare's resolvers.
  # Bootstrapping is fine, as the existing bootstrap entry resolves
  # dns.quad9.net.
  conditional = {
    mapping =
      let
        unfiltered = "tcp-tls:dns.quad9.net";
      in
      {
        "archive.today" = unfiltered;
        "archive.fo" = unfiltered;
        "archive.is" = unfiltered;
        "archive.li" = unfiltered;
        "archive.md" = unfiltered;
        "archive.ph" = unfiltered;
        "archive.vn" = unfiltered;
      };
  };
  caching = {
    minTime = "6h";
    maxTime = "24h";
    prefetchExpires = "24h";
    prefetching = true;
  };
  prometheus.enable = true;
  customDNS = {
    rewrite = {
      #local = "alq.ae"; # resolves everything to alq.ae

      # Safe search
      #"google.*" = "forcesafesearch.google.com";
      #"www.google.*" = "forcesafesearch.google.com";
      #"google.com" = "forcesafesearch.google.com";
      #"www.google.com" = "forcesafesearch.google.com";

      #"www.youtube.com" = "restrict.youtube.com";
      #"m.youtube.com" = "restrict.youtube.com";
      #"youtubei.googleapis.com" = "restrict.youtube.com";
      #"youtube.googleapis.com" = "restrict.youtube.com";
      #"www.youtube-nocookie.com" = "restrict.youtube.com";

      #"www.bing.com" = "strict.bing.com";
      #"duckduckgo.com" = "strict.duckduckgo.com";
      #"www.ecosia.org" = "strict-safe-search.ecosia.org";
    };
    mapping = {
      #"www.google.com" = "216.239.38.120";
      #"www.google.ae" = "216.239.38.120";
      #"www.google.co.uk" = "216.239.38.120";

      #"www.youtube.com" = "216.239.38.119";
      #"m.youtube.com" = "216.239.38.119";
      #"youtubei.googleapis.com" = "216.239.38.119";
      #"youtube.googleapis.com" = "216.239.38.119";
      #"www.youtube-nocookie.com" = "216.239.38.119";

      # way to test
      "test.huma.id" = "1.1.1.1";

      # routers
      "v6.alq.ae" = "10.20.0.1";
      "v10.alq.ae" = "192.168.50.1";

      # Nebula
      "lighthouse.s.alq.ae" = "10.10.0.10";
      "serow.s.alq.ae" = "10.10.0.11";
      "oreamnos.s.alq.ae" = "10.10.0.12";
      "duisk.s.alq.ae" = "10.10.0.13";
      "anoa.s.alq.ae" = "10.10.0.14";
      "pixel.s.alq.ae" = "10.10.0.15";
      "bongo.s.alq.ae" = "10.10.0.16";
      "bingo.s.alq.ae" = "10.10.0.18";

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
      # Every group defined under denylists belongs here. A group that is
      # defined and not listed is downloaded and then never consulted, which is
      # what had happened to devdan — its two lists had never blocked anything.
      default = [
        "general"
        "steven"
        "devdan"
        "extras"
        "ips"
        "ut1"
        "custom"
        "doh"
        "vpn"
        "nrd"
      ];
    };
    denylists = {
      # Hagezi block lists: https://github.com/hagezi/dns-blocklists?tab=readme-ov-file
      general = [
        # Pro List
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.plus.txt"
        # Threat Intelligence Feeds
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.txt"
        # Gambling
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/gambling.txt"
        # Pop-up Ads
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/popupads.txt"
        # Fake Sites & Scams
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/fake.txt"
        # DynDNS sites
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/dyndns.txt"
        # Piracy. Previously carried in allowlists.general, where its ~38k
        # entries beat every denylist unconditionally — that is what made
        # *.imoim.app in custom-blocklist.txt a silent no-op, since the list
        # covers it and imo's gateway and LBS hosts live in that zone.
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/anti.piracy.txt"
      ];

      steven = [
        # StevenBlack Hosts
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts"
      ];

      devdan = [
        "https://www.github.developerdan.com/hosts/lists/hate-and-junk-extended.txt"
        "https://www.github.developerdan.com/hosts/lists/dating-services-extended.txt"
      ];

      extras = [
        # DMCA abusers
        "https://paulgb.github.io/BarbBlock/blacklists/hosts-file.txt"

        # Windows telemetry
        "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"

        # Smart TV telemetry
        "https://blocklistproject.github.io/Lists/smart-tv.txt"

        # Native devices
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.xiaomi.txt"
        #"https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.apple.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.amazon.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.oppo-realme.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.vivo.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.roku.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.lgwebos.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.tiktok.extended.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.samsung.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/domains/native.winoffice.txt"
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.huawei.txt"

        # Recommended by hagezi
        "https://nsfw.oisd.nl/domainswild"

        # Classroom Monitoring
        "https://raw.githubusercontent.com/hapara-fail/blocklist/main/blocklist.txt"

        # Sefinek Block Lists
        "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus.txt"
        "https://blocklist.sefinek.net/generated/v1/0.0.0.0/sites/lgbtqplus2.txt"
        "https://blocklist.sefinek.net/generated/v1/0.0.0.0/anime/main.txt"

        # Firebog lists
        "https://v.firebog.net/hosts/static/w3kbl.txt"
        "https://v.firebog.net/hosts/neohostsbasic.txt"
        "https://raw.githubusercontent.com/RooneyMcNibNug/pihole-stuff/master/SNAFU.txt"

        # Unsafe sites list
        "https://raw.githubusercontent.com/fmhy/FMHYFilterlist/main/filterlist-wildcard-domains.txt"
      ];

      # Old list but may fill some gaps
      ut1 = [
        "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/astrology/domains"
        "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/agressif/domains"
        "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/dating/domains"
        "https://raw.githubusercontent.com/olbat/ut1-blacklists/refs/heads/master/blacklists/sect/domains"
      ];

      ips = [
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
        "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt"
      ];

      custom = [
        "${./custom-blocklist.txt}"
      ];

      # Block DoH provider hostnames so clients cannot bootstrap a
      # DNS-over-HTTPS resolver by name and tunnel past the router's resolver.
      #
      # doh-vpn-proxy-bypass rather than plain doh: the narrow list holds only
      # resolver hostnames, and every bypass endpoint that actually turned up
      # in the query history sits one layer out from that — a VPN's API host, a
      # control plane on API Gateway, a proxy on rented hosting. Measured
      # against the 157 such names still resolving here, doh.txt caught none of
      # them and this list catches 139.
      #
      # It is safe to widen to because it names hosts rather than zones where
      # the zone is shared: vpn-api.proton.me and not proton.me, which would
      # take Mail and Drive with it; the individual API Gateway hostnames and
      # not execute-api.*.amazonaws.com; mask-h2.icloud.com and not icloud.com.
      #
      # Do not read that as covering iCloud Private Relay. Verified 2026-08-11
      # by querying both resolvers: this list carries mask-h2.icloud.com, the
      # HTTP/2 fallback, and NOT mask.icloud.com, the primary QUIC ingress,
      # which resolved fine on both sites while Private Relay was live on
      # nineteen devices. Both names are pinned in custom-blocklist.txt now.
      #
      # It does carry tailscale.com, so the mesh goes down with it. That is the
      # one thing here worth a deliberate decision rather than a default.
      doh = [
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/doh-vpn-proxy-bypass.txt"
      ];

      vpn = [
        "https://az0-vpnip-public.oooninja.com/adguard.txt"
      ];

      # Newly registered domains, first three weeks of life. The throwaway
      # front pools in custom-blocklist.txt are the argument for this: those
      # estates burn and re-register domains faster than any list names them
      # individually, and age is the one property the rotation cannot fake.
      #
      # Days 1-21 only. The 28-22 and 35-29 slices are deliberately left out —
      # by four weeks a domain is as likely to be someone's new small site as
      # an operator's next front, and the hit rate does not justify the false
      # positives.
      #
      # Checked before enabling: of the 26,054 names this network has resolved
      # in four months, these three lists catch 20, and most of those are junk
      # already blocked by name here (phzzz1.com, wpofs.com, the wjpeso pair).
      # covid.gov, recipetables.com and codex-resets.com are the genuine false
      # positives, and were accepted knowingly.
      #
      # They need no allowlist entry: the three slices cover days 1-7, 8-14 and
      # 15-21, so a domain leaves the last of them 21 days after it was
      # registered and unblocks itself. Every false positive here is therefore
      # temporary, which is the property that makes an age-based list cheap to
      # run — anything still blocked after three weeks is blocked by one of the
      # other groups, not this one.
      #
      # Note the size — about 7.7 million names across the three, which is an
      # order of magnitude more than everything else here combined, and shows
      # up as blocky's resident memory.
      nrd = [
        "https://raw.githubusercontent.com/hagezi/nrd/main/adblock/nrd7.txt"
        "https://raw.githubusercontent.com/hagezi/nrd/main/adblock/nrd14-8.txt"
        "https://raw.githubusercontent.com/hagezi/nrd/main/adblock/nrd21-15.txt"
      ];
    };
    allowlists = {
      # Only genuine allowlists belong here. A denylist parked in this slot is
      # silently inverted into 2,600-odd permanent exemptions that beat every
      # denylist, which is what blocklistproject's torrent.txt was doing until
      # it was removed: it held the whole public tracker estate plus names like
      # finbytes.org that hagezi's anti-piracy list was already trying to
      # block. Same mistake anti.piracy itself was making — see the note on it
      # under denylists.general.
      #
      # Removing it does block the distro torrents that list also carries, so
      # those are named in custom-whitelist.txt.
      general = [
        "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt"
        "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt"
        "${./custom-whitelist.txt}"
      ];
    };
  };
}
