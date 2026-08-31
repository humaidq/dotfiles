{
  # THE ISP'S OWN RESOLVERS, and the reason is CDN steering rather than speed
  # for its own sake. Measured from bongo on 2026-08-31 over 6,266 domains taken
  # from this router's own query log.
  #
  # Cloudflare sends no EDNS Client Subnet, by policy and on every one of its
  # addresses — 1.1.1.1 measured identically to 1.1.1.3, so this is not the
  # family filter. Meta and TikTok steer on ECS specifically, so without it
  # their authoritatives cannot see the client network and never return the FNA
  # cache sitting inside Etisalat. The cost was large and paid on every new
  # connection: Meta/TikTok IPv4 connect 76-92 ms via Cloudflare against 6-12 ms
  # here, and IPv6 reachability of 2/14 against 14/14 — the rest being SYNs into
  # a blackhole with no ICMP, which a client can only resolve by timing out.
  # That is what "some apps are slow, then recover, then a different one
  # degrades" was: a different edge on every lookup.
  #
  # These also win on plain latency, but only once the measurement is done
  # properly. Aggregated over all 6,266 names every resolver looks identical
  # (p50 110-127 ms) because 68% of logged names are NXDOMAIN. Split out the
  # ~2,000 that actually resolve — the only ones anything waits on — and it is
  # p50 4 ms / 89% under 30 ms here, against 13 ms / 74% for cf-family and
  # 37 ms / 41% for Google. Google was the worst of the four; its nearby anycast
  # frontend says nothing about its recursion, which is Google's own documented
  # warning.
  #
  # Dubai first because this line is in Dubai (the PTRs are dxbcns and auhcns
  # .ecompany.ae, one resolver per emirate); `strict` tries them in order, so
  # Abu Dhabi is the failover.
  #
  # WHAT THIS GIVES UP, all three deliberate:
  #   * DoT. Both have 853 closed, so this is plaintext 53 to the ISP. Only the
  #     router speaks it — LAN clients are still forced onto blocky, and
  #     LAN->WAN 53/853 stays dropped in modules/router/default.nix.
  #   * DNSSEC validation. Neither sets the ad flag. They do NOT strip it,
  #     though — RRSIG, DNSKEY and DS all come back intact, so a validator
  #     downstream could still verify; blocky is not one.
  #   * Cloudflare's family filter. The denylists below (oisd nsfw, StevenBlack,
  #     ut1) were always doing most of that work and are unaffected.
  #
  # Checked and not a problem: no ad or tracker filtering of their own
  # (doubleclick, googleadservices, scorecardresearch and friends all resolve
  # normally), no NXDOMAIN hijacking, and 6 disagreements with Google across
  # 6,266 domains, all transient. Re-measure before trusting any of this; see
  # the resolver-steering notes for how the small-sample versions misled.
  upstreams = {
    strategy = "strict";
    groups = {
      default = [
        "213.42.20.20" # dxbcns.ecompany.ae
        "195.229.241.222" # auhcns.ecompany.ae
      ];
    };
  };
  # Plain IPs need no bootstrap to be reached, but blocky also resolves the
  # denylist download URLs through this, and the system resolver on a router is
  # blocky itself. Pointed at the same two so list refreshes do not depend on
  # blocky already being up.
  bootstrapDns = [
    { upstream = "213.42.20.20"; }
    { upstream = "195.229.241.222"; }
  ];
  # The archive.today mirrors used to be routed to Quad9 here, because
  # Cloudflare answered 0.0.0.0 for all seven of them (its own classification —
  # 1.1.1.2 did it too, so not the family filter) and no blocklist change could
  # fix an upstream sinkhole. That mapping is gone because the upstream above no
  # longer needs it: verified 2026-08-31 that both Etisalat resolvers return the
  # real 185.14.97.131 for all seven of .today .fo .is .li .md .ph .vn.
  #
  # Removing it also drops the last upstream that was a hostname rather than an
  # address, which is what lets bootstrapDns above be two plain IPs.
  #
  # The names stay in custom-whitelist.txt; that is unrelated and still needed.
  caching = {
    # Honour real TTLs; do not hold anything past what its zone said. There are
    # two independent reasons and both apply to every host that imports this.
    #
    # The DHCP one, which is why this was already forced to 0 in dns.nix before
    # it moved here: blocky's cache sits in front of its conditional resolver,
    # so a 6h floor pinned DHCP hostname-to-address mappings for 6h after a
    # lease changed.
    #
    # The steering one, which is new and is the reason not to raise it again.
    # The upstreams above are chosen because they return the in-country CDN
    # cache, and they do that by asking the authoritative on our behalf every
    # time the record expires — those answers carry 30-60s TTLs precisely so
    # the CDN can move clients. A 6h floor would pin the whole LAN to one edge
    # for 6h and re-create, locally, the stale-steering problem the upstream
    # change just fixed.
    #
    # Cheap now in a way it was not before: the p50 lookup against these
    # resolvers is 4 ms with 89% under 30 ms, so re-resolving on real TTLs
    # costs far less than it did against a 13-37 ms upstream, and prefetching
    # below keeps hot names warm regardless.
    minTime = "0";
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
      "serow.s.alq.ae" = "10.10.0.11";
      "oreamnos.s.alq.ae" = "10.10.0.12";
      "anoa.s.alq.ae" = "10.10.0.14";
      "pixel.s.alq.ae" = "10.10.0.15";
      "bongo.s.alq.ae" = "10.10.0.16";
      "bingo.s.alq.ae" = "10.10.0.18";
      "hisn.s.alq.ae" = "10.10.0.20";

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
