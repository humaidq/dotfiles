{
  lib,
  config,
  pkgs,
  ...
}:

let
  ipBlocklistUrls = [
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/tif.txt"
    "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt"
    "https://az0-vpnip-public.oooninja.com/ip.txt"
    "https://raw.githubusercontent.com/X4BNet/lists_vpn/refs/heads/main/output/vpn/ipv4.txt"
  ];

  # Known DoH (DNS-over-HTTPS) endpoint IPs. All forwarded LAN->WAN traffic to
  # these is dropped, on every port, so clients cannot tunnel DNS past the
  # router's resolver and blocklists. The router itself is unaffected because
  # the sets are used only in the forward hook — which matters more than it
  # looks: blocky's upstream family.cloudflare-dns.com is 1.1.1.3 / 1.0.0.3,
  # both on this list, so applying it to the output path would break the
  # router's own resolution.
  dohBlocklistUrls = [
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/ips/doh.txt"
  ];

  # Optional whitelists
  allow4 = [ ];
  allow6 = [ ];
  cfg = config.sifr.router;

  # Feeds processed by the update service. Each entry maps a pair of nftables
  # sets to its source URLs and a minimum-size sanity guard that rejects
  # obviously broken / truncated downloads.
  #
  # custom-ip-blocklist.txt is deliberately NOT a feed here: it is a static file
  # in the store, so it wants a different trigger entirely. See local_block4/6
  # and nft-blocklists-local below.
  feeds = [
    {
      set4 = "remote_block4";
      set6 = "remote_block6";
      urls = ipBlocklistUrls;
      minEntries = 1000;
    }
    {
      set4 = "doh_block4";
      set6 = "doh_block6";
      urls = dohBlocklistUrls;
      minEntries = 100;
    }
  ];

  # The local blocklist is converted to nftables elements at build time rather
  # than at runtime like the feeds above, which buys two things. A malformed
  # line fails `nixos-rebuild` instead of being silently skipped the way the
  # runtime parser's `except ValueError: continue` skips it, and applying the
  # result needs no network, so these entries land even when every feed
  # download has failed.
  localBlocklistGen = pkgs.writeText "gen-local-blocklist.py" ''
    import ipaddress
    import pathlib
    import sys

    src, dst, table, set4, set6 = sys.argv[1:6]

    allow = set(filter(None, """${lib.concatStringsSep "\n" (allow4 ++ allow6)}""".splitlines()))

    v4 = []
    v6 = []
    seen = set()

    for lineno, line in enumerate(pathlib.Path(src).read_text().splitlines(), 1):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        try:
            net = ipaddress.ip_network(s, strict=False)
        except ValueError as exc:
            # Loud, unlike the feed parser: this file is ours, so a line that is
            # not an address is a typo that would otherwise block nothing and
            # say nothing.
            raise SystemExit(f"{src}:{lineno}: not an IP address or CIDR: {s!r} ({exc})")

        if str(net) in allow or net in seen:
            continue
        seen.add(net)
        (v4 if net.version == 4 else v6).append(net)

    # nftables interval sets reject overlapping elements ("conflicting
    # intervals specified") unless the set is declared auto-merge, so a
    # broad entry added next to a narrower one already in the file would
    # otherwise fail the whole `nft -f` at runtime. Collapsing here keeps
    # the txt free to list whatever is clearest — 169.136.140.0/24 from an
    # AS listing and the wider 169.136.140.0/22 that contains it, say — and
    # merges adjacent prefixes into the shortest equivalent set as a bonus.
    v4 = [str(n) for n in ipaddress.collapse_addresses(v4)]
    v6 = [str(n) for n in ipaddress.collapse_addresses(v6)]

    with pathlib.Path(dst).open("w") as f:
        for name, elems in ((set4, v4), (set6, v6)):
            f.write(f"flush set inet {table} {name}\n")
            if elems:
                f.write(f"add element inet {table} {name} {{\n")
                for i, elem in enumerate(elems):
                    comma = "," if i + 1 < len(elems) else ""
                    f.write(f"  {elem}{comma}\n")
                f.write("}\n")

    print(f"local blocklist: {len(v4)} IPv4, {len(v6)} IPv6", file=sys.stderr)
  '';

  localBlocklist =
    pkgs.runCommand "nft-local-blocklist.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-ip-blocklist.txt} "$out" \
          router-blocklists local_block4 local_block6
      '';

  # Same build-time-not-runtime treatment as the local IP list above, for the
  # same two reasons: a typo fails the rebuild instead of silently blocking
  # nothing, and applying it needs no network.
  portBlocklistGen = pkgs.writeText "gen-port-blocklist.py" ''
    import pathlib
    import sys

    src, dst, table, setname = sys.argv[1:5]

    ports = []
    seen = set()

    for lineno, line in enumerate(pathlib.Path(src).read_text().splitlines(), 1):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        try:
            port = int(s)
        except ValueError:
            raise SystemExit(f"{src}:{lineno}: not a port number: {s!r}")
        if not 1 <= port <= 65535:
            raise SystemExit(f"{src}:{lineno}: port out of range: {port}")
        if port in seen:
            continue
        seen.add(port)
        ports.append(port)

    with pathlib.Path(dst).open("w") as f:
        f.write(f"flush set inet {table} {setname}\n")
        if ports:
            f.write(f"add element inet {table} {setname} {{\n")
            for i, port in enumerate(sorted(ports)):
                comma = "," if i + 1 < len(ports) else ""
                f.write(f"  {port}{comma}\n")
            f.write("}\n")

    print(f"port blocklist: {len(ports)} ports", file=sys.stderr)
  '';

  portBlocklist =
    pkgs.runCommand "nft-port-blocklist.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${portBlocklistGen} ${./custom-port-blocklist.txt} "$out" \
          router-blocklists blocked_ports
      '';

  # Reuses portBlocklistGen verbatim, exactly as throttleList reuses
  # localBlocklistGen: same format, same build-time validation, only the
  # target set differs.
  lowTrustPorts =
    pkgs.runCommand "nft-lowtrust-ports.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${portBlocklistGen} ${./custom-lowtrust-ports.txt} "$out" \
          router-blocklists lowtrust_ports
      '';

  lowTrustSubnets =
    pkgs.runCommand "nft-lowtrust-subnets.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-lowtrust-subnets.txt} "$out" \
          router-blocklists lowtrust_block4 lowtrust_block6
      '';

  # The carve-out from the ASN expansion. Same generator as the two lists above
  # — it is the same shape of input, a hand-written file of ranges — but it
  # feeds a set the policy chain RETURNS on rather than drops on.
  lowTrustAllow =
    pkgs.runCommand "nft-lowtrust-allow.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-lowtrust-allow-subnets.txt} "$out" \
          router-blocklists lowtrust_allow4 lowtrust_allow6
      '';

  # Addresses that no generated range may ever swallow. Not a general whitelist
  # — it is a tripwire for the ASN expansion below, which turns fifteen numbers
  # into millions of addresses and is therefore the one place in this repo where
  # a one-line edit can take out something the whole house needs without anyone
  # reading a diff that looks wrong.
  #
  # Each entry is something already established as load-bearing: the resolver
  # every device uses, the two Akamai edge ranges this network actually reaches,
  # the STUN server legitimate calls discover through, the CDN carrying ordinary
  # browsing, and this operator's own infrastructure. A build that would block
  # any of them fails rather than shipping.
  lowTrustNeverCover = [
    "1.1.1.1" # Cloudflare resolver
    "1.0.0.1"
    "95.100.170.42" # Akamai edge this network reaches constantly
    "23.44.201.155" # the second Akamai edge range, seen fronting
    "74.125.250.129" # stun.l.google.com — discovery for legitimate calls
    "185.93.2.251" # BunnyCDN edge
    "143.244.56.58" # BunnyCDN edge
    "139.84.164.156" # huma.id
    "139.84.173.48" # nebula lighthouse
  ];

  # Expands a list of AS numbers into the CIDRs they announce, read from the
  # ip2asn table this repo already ships. An ASN list rather than pasted
  # prefixes because a provider's allocations change: the numbers stay true and
  # the ranges refresh with the table.
  # Parameterised on the never-cover list rather than closing over one, because
  # there are now two callers wanting different guards: the low-trust ASN
  # expansion below, which drops what it matches and therefore enforces the full
  # list, and the CDN quota expansion, which only shapes and must be allowed to
  # cover the four CDN edges on it. Everything else about the two is identical,
  # and a copy of this script that drifted would be worse than an argument.
  mkASNGen =
    name: neverCover:
    pkgs.writeText name ''
      import ipaddress
      import pathlib
      import sys

      src, table_path, dst, table, set4, set6 = sys.argv[1:7]

      never = [
          ipaddress.ip_address(a)
          for a in filter(None, """${lib.concatStringsSep "\n" neverCover}""".splitlines())
      ]

      wanted = {}
      for lineno, line in enumerate(pathlib.Path(src).read_text().splitlines(), 1):
          s = line.split("#", 1)[0].strip()
          if not s:
              continue
          if not s.isdigit():
              raise SystemExit(f"{src}:{lineno}: not an AS number: {s!r}")
          wanted[int(s)] = lineno

      v4 = []
      v6 = []
      seen_asns = set()

      for row in pathlib.Path(table_path).read_text().splitlines():
          parts = row.split("\t")
          if len(parts) < 3:
              continue
          try:
              asn = int(parts[2])
          except ValueError:
              continue
          if asn not in wanted:
              continue
          try:
              lo = ipaddress.ip_address(parts[0])
              hi = ipaddress.ip_address(parts[1])
          except ValueError:
              continue
          seen_asns.add(asn)
          for net in ipaddress.summarize_address_range(lo, hi):
              (v4 if net.version == 4 else v6).append(net)

      # An ASN the table has never heard of contributes nothing, which would be a
      # silent no-op — the failure mode this whole file is written against. A typo
      # in a five-digit number is invisible any other way.
      missing = sorted(a for a in wanted if a not in seen_asns)
      if missing:
          raise SystemExit(
              f"{src}: no ranges found for AS" + ", AS".join(str(a) for a in missing)
              + " — check the number, or that ip2asn-combined.tsv is current"
          )

      v4 = list(ipaddress.collapse_addresses(v4))
      v6 = list(ipaddress.collapse_addresses(v6))

      # The tripwire. Cheap to run, and the only thing standing between a
      # mistyped AS number and the whole house losing its resolver or its CDN.
      for addr in never:
          pool = v4 if addr.version == 4 else v6
          for net in pool:
              if addr in net:
                  raise SystemExit(
                      f"{src}: refusing to build — {addr} is inside {net}, which one of "
                      "these AS numbers announces. That address is on the never-block "
                      "list; remove the offending ASN or narrow the range."
                  )

      v4 = [str(n) for n in v4]
      v6 = [str(n) for n in v6]

      with pathlib.Path(dst).open("w") as f:
          for name, elems in ((set4, v4), (set6, v6)):
              f.write(f"flush set inet {table} {name}\n")
              if elems:
                  f.write(f"add element inet {table} {name} {{\n")
                  for i, elem in enumerate(elems):
                      comma = "," if i + 1 < len(elems) else ""
                      f.write(f"  {elem}{comma}\n")
                  f.write("}\n")

      print(
          f"{pathlib.Path(src).name}: {len(wanted)} ASNs -> {len(v4)} IPv4, {len(v6)} IPv6",
          file=sys.stderr,
      )
    '';

  lowTrustASNGen = mkASNGen "gen-lowtrust-asns.py" lowTrustNeverCover;

  lowTrustASNs =
    pkgs.runCommand "nft-lowtrust-asns.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${lowTrustASNGen} ${./custom-lowtrust-asns.txt} ${./ip2asn-combined.tsv} "$out" \
          router-blocklists lowtrust_asn4 lowtrust_asn6
      '';

  # The CDN quota set reuses the ASN expander with ONE difference, and it is the
  # difference that needs justifying rather than the reuse.
  #
  # lowTrustNeverCover exists because that generator turns a five-digit number
  # into millions of addresses that get DROPPED. Four of its nine entries are
  # CDN edges — 95.100.170.42, 23.44.201.155, 185.93.2.251, 143.244.56.58 — and
  # those four are precisely what a CDN quota has to cover, so the unmodified
  # guard makes this file impossible to build.
  #
  # The guard is NARROWED rather than removed: the four CDN edges are exempted
  # and the other five are still enforced, so nothing generated from
  # custom-cdn-quota-asns.txt can ever swallow the resolver, the STUN server or
  # this operator's own hosts. Exempting the four is safe only because a match
  # here shapes to the throttle tier instead of dropping, and only ever for a
  # pool device. Both properties are stated in that file's header as the terms
  # of the exemption.
  cdnQuotaNeverCover = builtins.filter (
    a:
    !(builtins.elem a [
      "95.100.170.42"
      "23.44.201.155"
      "185.93.2.251"
      "143.244.56.58"
    ])
  ) lowTrustNeverCover;

  cdnQuotaASNGen = mkASNGen "gen-cdn-quota-asns.py" cdnQuotaNeverCover;

  cdnQuotaASNs =
    pkgs.runCommand "nft-cdn-quota-asns.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${cdnQuotaASNGen} ${./custom-cdn-quota-asns.txt} ${./ip2asn-combined.tsv} "$out" \
          router-blocklists cdn_quota4 cdn_quota6
      '';

  # Every unit below that writes elements into an nftables set carries this, and
  # leaving it off one is a silent, total fail-open. It is the fix for an outage
  # on 2026-08-15 in which every set on both routers sat empty for over an hour:
  # 1706 throttle entries, the whole low-trust pool, and all the local
  # blocklists, with all three loader units reporting success the whole time.
  #
  # The mechanism, which the partOf reasoning further down does NOT cover.
  # NixOS sets reloadIfChanged on nftables.service, so a ruleset change is
  # applied by systemctl RELOAD, not restart. That reload re-runs the module's
  # rulesScript, which deletes and recreates every managed table — and a
  # recreated table has empty sets. PartOf propagates stop and restart. It
  # propagates nothing at all on a reload, to any unit, regardless of
  # RemainAfterExit. So the tables were emptied and no loader re-ran.
  #
  # This went unnoticed for as long as it did because it needs a ruleset change
  # that touches NO list file. Editing custom-throttle-list.txt or any sibling
  # changes a generated .nft store path, which changes nft-blocklists-local's
  # ExecStart, which restarts it anyway and hides the bug. The outage came from
  # a change to the inline ruleset in this file, which moves the ExecStart of
  # nothing.
  #
  # Keyed on nftables.service's ExecReload because that list contains the
  # rulesScript store path, so it changes if and only if the applied ruleset
  # does — including a change that comes from networking.firewall rather than
  # from this file, which reloads and flushes these tables just the same. Keying
  # on this module's own tables would miss exactly that case.
  #
  # Ordering is guaranteed rather than hoped for: switch-to-configuration issues
  # every reload, blocks on those jobs completing, and only then issues the
  # restarts (block_on_jobs in switch-to-configuration-ng). So the flush has
  # finished before any loader here re-runs. That ordering is also why this is
  # preferable to forcing reloadIfChanged off — a restart would run
  # nftables.service's ExecStop, which deletes the tables outright and leaves
  # the router with no firewall at all until the start completed.
  #
  # Not covered: a hand-run `systemctl reload nftables`. Nothing declarative can
  # observe that, so follow one with a restart of the three units carrying this.
  nftRulesetTrigger = [ config.systemd.services.nftables.serviceConfig.ExecReload ];

  # The throttle list reuses the local blocklist's generator verbatim — same
  # format, same build-time validation, same interval collapsing — and only the
  # target sets differ. What happens to a matching packet is decided in the
  # ruleset and in tc, not here.
  throttleList =
    pkgs.runCommand "nft-throttle-list.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-throttle-list.txt} "$out" \
          router-blocklists throttle4 throttle6
      '';

  # Same generator again, third and fourth targets. See the note on
  # throttleList above: the file format and validation are identical and only
  # the set names differ, because what happens to a matching packet is decided
  # in the ruleset and in tc rather than here.
  #
  # One source file, two destinations, because imo's estate is either shaped or
  # dropped depending on the day and on the host — see imoPolicy. Which pair is
  # populated is what carries that decision.
  imoList =
    pkgs.runCommand "nft-imo-list.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-imo-list.txt} "$out" \
          router-blocklists imo4 imo6
      '';

  imoBlockList =
    pkgs.runCommand "nft-imo-block-list.nft"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${localBlocklistGen} ${./custom-imo-list.txt} "$out" \
          router-blocklists imo_block4 imo_block6
      '';

  # The two states imo-policy.service switches between, each a single file that
  # fills one pair of sets and empties the other. One file rather than two `nft`
  # calls because `nft -f` is one transaction: the estate is never in both pairs
  # at once, and never briefly in neither.
  imoThrottleState = pkgs.runCommand "nft-imo-state-throttle.nft" { } ''
    cat ${imoList} > "$out"
    printf 'flush set inet router-blocklists imo_block4\n' >> "$out"
    printf 'flush set inet router-blocklists imo_block6\n' >> "$out"
  '';

  imoBlockState = pkgs.runCommand "nft-imo-state-block.nft" { } ''
    cat ${imoBlockList} > "$out"
    printf 'flush set inet router-blocklists imo4\n' >> "$out"
    printf 'flush set inet router-blocklists imo6\n' >> "$out"
  '';

  # Prints the mode in force — "block" or "throttle" — for today, or for the
  # day-of-month given as an argument. Split out of the service and exposed in
  # systemPackages rather than inlined: a schedule you cannot interrogate for a
  # date other than now is one you find out about by waiting for it.
  #
  # 10# forces base ten, otherwise "08" and "09" are invalid octal and the
  # arithmetic fails on exactly two days of the month.
  imoPolicyToday = pkgs.writeShellApplication {
    name = "imo-policy-today";
    runtimeInputs = [ pkgs.coreutils ];
    text =
      if cfg.imoPolicy == "alternate" then
        ''
          day=''${1:-$(date +%d)}

          if [ $(( 10#$day % 2 )) -eq 1 ]; then
            echo block
          else
            echo throttle
          fi
        ''
      else
        ''
          # Fixed policy on this host, so the day is irrelevant and any
          # argument is accepted and ignored — a caller checking next Tuesday
          # gets the same true answer as one checking today.
          echo "${cfg.imoPolicy}"
        '';
  };
in
{

  config = lib.mkIf cfg.enable {
    networking.nftables.enable = true;

    networking.nftables.tables.router-blocklists = {
      family = "inet";
      content = ''
        set remote_block4 {
          type ipv4_addr
          flags interval
        }

        set remote_block6 {
          type ipv6_addr
          flags interval
        }

        set doh_block4 {
          type ipv4_addr
          flags interval
        }

        set doh_block6 {
          type ipv6_addr
          flags interval
        }

        # Populated from custom-ip-blocklist.txt by nft-blocklists-local, which
        # runs during `nixos-rebuild switch` rather than on the feed timer.
        set local_block4 {
          type ipv4_addr
          flags interval
        }

        set local_block6 {
          type ipv6_addr
          flags interval
        }

        # Populated from custom-throttle-list.txt by nft-blocklists-local, and
        # also the set `tempthrottle` adds to at runtime. Matching packets are
        # marked rather than dropped; the shaping itself lives in tc, see
        # qos.nix.
        set throttle4 {
          type ipv4_addr
          flags interval
        }

        set throttle6 {
          type ipv6_addr
          flags interval
        }

        # Populated from custom-imo-list.txt by imo-policy, on the days that
        # host is throttling rather than blocking. Marked 0x3 rather than 0x2
        # so tc can steer it into a class of its own: imo is rate capped and
        # lossy, not crippled outright the way a tunnel node is.
        set imo4 {
          type ipv4_addr
          flags interval
        }

        set imo6 {
          type ipv6_addr
          flags interval
        }

        # The other half of that switch: the same file, dropped instead of
        # shaped. Exactly one of these two pairs holds the estate at any moment
        # — see imo-policy.service. Both are declared unconditionally, so a
        # host set to "throttle" simply leaves these empty and the drop rules
        # below never match.
        set imo_block4 {
          type ipv4_addr
          flags interval
        }

        set imo_block6 {
          type ipv6_addr
          flags interval
        }

        # Populated from custom-port-blocklist.txt by nft-blocklists-local.
        # Plain set rather than an interval one: the entries are discrete ports,
        # and a range has never been needed. Adding `flags interval` later is a
        # one-line change if that stops being true.
        set blocked_ports {
          type inet_service
        }

        ${lib.optionalString cfg.lowTrust.enable ''
          # Membership in the low-trust pool, matched as `ether saddr`, which is
          # only visible on the LAN-ingress (upload) direction — a download's
          # source MAC is the ISP's. That is sufficient because every consumer
          # either drops the packet outright or sets a ct mark, and a ct mark
          # applies to both directions of the conversation.
          #
          # Two sets rather than one so that removal is safe: the peers page can
          # only touch the _temp set, so a button press can never silently undo
          # a device that was deliberately put in the permanent list. A device
          # in both is simply in the pool.
          set lowtrust_macs {
            type ether_addr
          }

          set lowtrust_macs_temp {
            type ether_addr
          }

          set lowtrust_ports {
            type inet_service
          }

          set lowtrust_block4 {
            type ipv4_addr
            flags interval
          }

          set lowtrust_block6 {
            type ipv6_addr
            flags interval
          }

          # Whole hosting networks, expanded from custom-lowtrust-asns.txt.
          # Kept apart from lowtrust_block4/6 rather than merged into them
          # because each generated .nft flushes the sets it writes: two
          # generators sharing one set would clobber each other, and this file
          # already states the rule as one writer per set.
          #
          # The practical difference to a reader is scope. lowtrust_block4/6 is
          # for ranges chosen by hand, a few at a time. This pair is thousands
          # of prefixes derived from a provider list, and is the reason a pool
          # device cannot simply rotate to the next VPS.
          set lowtrust_asn4 {
            type ipv4_addr
            flags interval
          }

          set lowtrust_asn6 {
            type ipv6_addr
            flags interval
          }

          # The carve-out from the pair above, expanded from
          # custom-lowtrust-allow-subnets.txt. Its own set and its own generator
          # for the same one-writer-per-set reason given for lowtrust_asn4/6.
          #
          # A set rather than a handful of literal ranges in the chain because
          # the list is expected to grow: the ASN expansion turns 29 provider
          # numbers into millions of addresses, and every app the house depends
          # on that rents from one of those providers will need an entry here
          # the first time someone notices it is broken.
          set lowtrust_allow4 {
            type ipv4_addr
            flags interval
          }

          set lowtrust_allow6 {
            type ipv6_addr
            flags interval
          }

          # Populated from custom-lowtrust-stun-hosts.txt by nft-lowtrust-stun,
          # on a timer rather than at build time because these names resolve to
          # addresses that move. No `flags interval`: these are host addresses
          # from DNS, not ranges.
          set lowtrust_stun4 {
            type ipv4_addr
          }

          set lowtrust_stun6 {
            type ipv6_addr
          }
        ''}

        ${lib.optionalString (cfg.lowTrust.enable && cfg.lowTrust.cdnQuota.enable) ''
          # CDN space subject to the volume quota, expanded from
          # custom-cdn-quota-asns.txt. Nothing here is ever dropped — these two
          # sets exist only to say "this destination is a CDN edge", and the
          # decision about what to do is made by the rate limiter below.
          set cdn_quota4 {
            type ipv4_addr
            flags interval
          }

          set cdn_quota6 {
            type ipv6_addr
            flags interval
          }

          # One token bucket per pool device, created and refreshed by the
          # `update` statements in lowtrust_cdn_quota. The element key is the
          # DEVICE's address in both directions, so a device has one budget
          # covering its CDN traffic either way rather than two independent
          # allowances.
          #
          # The timeout only reaps idle entries; it is not the quota window.
          # The window is the token bucket's own refill and needs no timer,
          # which is the whole reason this is a dynamic set rather than a
          # named quota object plus a reset unit.
          set cdn_over4 {
            type ipv4_addr
            flags dynamic, timeout
            timeout 2h
            size 1024
          }

          set cdn_over6 {
            type ipv6_addr
            flags dynamic, timeout
            timeout 2h
            size 1024
          }

          # Which device-and-peer pairs the quota is ACTUALLY shaping right
          # now, as opposed to cdn_over4/6 above, which says only that a device
          # has a budget open. The difference is the whole reason this set
          # exists: being over budget was previously observable nowhere except
          # the aggregate rule counters, so the peers page could not say why an
          # Akamai edge was being held back, and an operator reading that page
          # saw a peer with no status at all.
          #
          # Written to only by the statements that sit AFTER the
          # `limit rate over` expression in lowtrust_cdn_quota, which is what
          # makes membership mean "over budget" rather than "in scope": nft
          # stops evaluating a rule at the first expression that does not
          # match, so these adds are reached on exactly the packets that get
          # the throttle mark.
          #
          # Keyed on the pair rather than on the device alone because that is
          # the question the page asks — this device, this peer — and because a
          # device pulling hard from one CDN says nothing about a second CDN it
          # is also talking to. The two rules per family are written so the
          # device is always the first element and the peer the second, despite
          # saddr and daddr swapping roles between the upload and download
          # rules.
          #
          # The timeout is a display window, not a quota window. A quota that
          # fires in bursts would otherwise flicker the page's badge on and off
          # between renders, which reads as a fault rather than as shaping; 5
          # minutes is long enough to stay lit across a gap and short enough
          # that a badge means something current. The bucket in cdn_over4/6 is
          # unaffected either way — nothing reads this set but the web UI.
          #
          # Bounded by size: an add against a full set fails and the packet
          # carries on to the counter and the mark, so a saturated set costs
          # visibility on new pairs and never shaping. 4096 against the 1024
          # devices cdn_over4 allows is four CDN peers apiece within one
          # window, and a device fanning out wider than that is one whose badge
          # is already lit from its first peer.
          set cdn_throttled4 {
            type ipv4_addr . ipv4_addr
            flags dynamic, timeout
            timeout 5m
            size 4096
          }

          set cdn_throttled6 {
            type ipv6_addr . ipv6_addr
            flags dynamic, timeout
            timeout 5m
            size 4096
          }
        ''}

        chain forward_blocklists {
          type filter hook forward priority -10; policy accept;

          # Log before dropping so blocked destinations are visible in Grafana
          # the way blocky's response_reason=BLOCKED lines already are. nft log
          # writes to the kernel ring buffer, journald picks it up, and alloy
          # ships the whole journal, so these arrive under {nodename="bongo"}
          # with no extra plumbing.
          #
          # The log and the drop are separate rules on purpose. Putting a limit
          # on the same rule as the verdict would mean packets *over* the rate
          # no longer match, and so would not be dropped either — the limit has
          # to gate only the logging. The rate is per rule and deliberately
          # low: a blocked app retries hard, so this is a sample of what is
          # being stopped, not an audit log. Counters are the thing to read for
          # volume (`nft list chain inet router-blocklists forward_blocklists`).
          ip daddr @remote_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-feed " comment "sample feed drops"
          ip6 daddr @remote_block6 limit rate 60/minute burst 20 packets log prefix "nft-block-feed " comment "sample feed drops"
          ip daddr @local_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-local " comment "sample local-list drops"
          ip6 daddr @local_block6 limit rate 60/minute burst 20 packets log prefix "nft-block-local " comment "sample local-list drops"
          ip daddr @imo_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-imo " comment "sample imo drops"
          ip6 daddr @imo_block6 limit rate 60/minute burst 20 packets log prefix "nft-block-imo " comment "sample imo drops"

          # Blocks LAN clients from reaching listed IPs
          ip daddr @remote_block4 counter drop comment "block forwarded IPv4 destinations"
          ip6 daddr @remote_block6 counter drop comment "block forwarded IPv6 destinations"
          ip daddr @local_block4 counter drop comment "block forwarded IPv4 destinations (local list)"
          ip6 daddr @local_block6 counter drop comment "block forwarded IPv6 destinations (local list)"

          # imo on a blocking day. Its own log prefix and its own counters
          # rather than sharing the local list's, because this pair comes and
          # goes on a schedule and the whole point of the counters is to answer
          # "did the block actually bite today".
          #
          # This chain is priority -10 and forward_throttle is priority 0, so
          # nothing has to be said here about the 0x3 marks: on a blocking day
          # the packet is dropped before the mark rules are ever reached.
          #
          # daddr only and forward only, matching the local list above — the
          # router's own output path is deliberately untouched, so imo remains
          # reachable from the router itself for diagnostics.
          ip daddr @imo_block4 counter drop comment "block forwarded IPv4 destinations (imo)"
          ip6 daddr @imo_block6 counter drop comment "block forwarded IPv6 destinations (imo)"
        }

        # Marks both directions of a throttled conversation so the tc filters in
        # qos.nix can steer it into the crippled class. Priority 0 puts this
        # after the drop chains at -10, which is deliberate: an address that is
        # both blocked and throttled should be dropped, and marking a packet
        # that is about to be dropped would be wasted work.
        #
        # Both saddr and daddr are matched because the two directions are shaped
        # on different interfaces — upload leaves via the PPP link where the
        # throttled address is the destination, download leaves via the LAN
        # interface where it is the source. One rule per direction per family
        # rather than a combined match, so the counters show which way the
        # traffic is actually flowing.
        chain forward_throttle {
          type filter hook forward priority 0; policy accept;

          ip daddr @throttle4 counter meta mark set 0x2 comment "throttle upload (IPv4)"
          ip saddr @throttle4 counter meta mark set 0x2 comment "throttle download (IPv4)"
          ip6 daddr @throttle6 counter meta mark set 0x2 comment "throttle upload (IPv6)"
          ip6 saddr @throttle6 counter meta mark set 0x2 comment "throttle download (IPv6)"

          # After the 0x2 rules deliberately. `meta mark set` overwrites, so an
          # address that somehow appears in both lists resolves to the imo
          # tier — which is the weaker of the two and therefore the safer
          # outcome for a misfiled address.
          #
          # Absent entirely on a host that only ever blocks imo: there is no
          # 1:30 class there for a mark to steer into, so these would set a
          # mark that nothing reads, on packets the chain above has already
          # dropped.
          ${lib.optionalString (cfg.imoPolicy != "block") ''
            ip daddr @imo4 counter meta mark set 0x3 comment "imo upload (IPv4)"
            ip saddr @imo4 counter meta mark set 0x3 comment "imo download (IPv4)"
            ip6 daddr @imo6 counter meta mark set 0x3 comment "imo upload (IPv6)"
            ip6 saddr @imo6 counter meta mark set 0x3 comment "imo download (IPv6)"
          ''}
        }

        chain forward_doh {
          type filter hook forward priority -10; policy accept;

          # Block LAN clients from reaching known DoH endpoints at all — every
          # port and protocol, not just 443. The narrower 443-only form this
          # replaces bought nothing: a DoH provider that shares an address with
          # general hosting serves that hosting over 443 too, so the collateral
          # was already being paid, while the leak of DoH on a non-standard
          # port stayed open.
          #
          # Still scoped LAN->WAN. The router itself is deliberately absent
          # from this chain and from output_blocklists, because blocky's own
          # upstream is a DoT endpoint that appears on this list — dropping it
          # from the output path would take out DNS for the whole house.
          #
          # Logged the same way as forward_blocklists — see the note there on
          # why the limit sits on its own rule rather than on the verdict.
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @doh_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-doh " comment "sample DoH drops"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @doh_block6 limit rate 60/minute burst 20 packets log prefix "nft-block-doh " comment "sample DoH drops"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @doh_block4 counter drop comment "Block LAN DoH bypass (IPv4)"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @doh_block6 counter drop comment "Block LAN DoH bypass (IPv6)"
        }

        chain forward_ports {
          type filter hook forward priority -10; policy accept;

          # Drop LAN -> WAN traffic to the ports in custom-port-blocklist.txt,
          # TCP and UDP alike. See that file for why this exists: imo rotates
          # its addresses faster than they can be blocked but has never changed
          # the ports its tunnel transport uses.
          #
          # Both protocols even though every capture showed TCP only. These are
          # non-standard ports carrying a proprietary protocol, so there is no
          # cost to covering the UDP form of the same trick, and an app that
          # already fails over between addresses, ports and DNS mechanisms is
          # not one to leave the option open for.
          #
          # Logged and dropped as separate rules for the reason given in
          # forward_blocklists — a limit on the verdict rule would let packets
          # over the rate through. Prefix is nft-block-port so it stays
          # separable from the other three in LogQL.
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @blocked_ports limit rate 60/minute burst 20 packets log prefix "nft-block-port " comment "sample blocked-port drops"
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @blocked_ports counter drop comment "block LAN->WAN tunnel ports"
        }

        ${lib.optionalString cfg.lowTrust.enable ''
          # Entry point for the pool. Two membership rules jumping to one policy
          # chain, so the policy is written once rather than duplicated per set.
          #
          # Priority -10 matches forward_ports and forward_blocklists, which
          # puts these drops ahead of forward_throttle at 0: a pool device
          # reaching a throttled address is dropped rather than shaped, matching
          # the precedence the other chains already establish.
          chain forward_lowtrust {
            type filter hook forward priority -10; policy accept;

            ether saddr @lowtrust_macs jump lowtrust_policy
            ether saddr @lowtrust_macs_temp jump lowtrust_policy

            ${lib.optionalString cfg.lowTrust.cdnQuota.enable ''
              # Entered on the conntrack sentinel, NOT on ether saddr like the
              # two rules above, and that difference is the whole reason this is
              # a separate chain.
              #
              # A MAC match only ever sees upload: a download's source MAC is the
              # ISP's. Every rule in lowtrust_policy is a drop, and dropping the
              # outbound packet is enough to stop a conversation, so the
              # one-directional match has never mattered there. It matters here.
              # The traffic this quota exists to shape is the DOWNLOAD half —
              # 45.5 MB down against 3.0 MB up in the capture that motivated it —
              # so a rule placed alongside those two would meter the 3 MB and
              # never see the 45 MB.
              #
              # qos.lowTrustMark is stamped on the upload path by MAC and rides
              # the conntrack entry in both directions; default.nix already
              # depends on exactly that property to catch the download half of
              # its own classification. Reused here rather than introducing a
              # pool-device IP set that would need its own loader and its own
              # staleness problem.
              ct mark ${toString cfg.qos.lowTrustMark} jump lowtrust_cdn_quota
            ''}
          }

          # Scoped LAN -> WAN, so traffic between LAN devices is untouched.
          # Traffic to the router itself needs no rule and gets none: it arrives
          # at the input hook, and this chain is on forward. That is
          # load-bearing rather than incidental — a pool device must keep
          # reaching the router's resolver, because one that cannot falls back
          # to something worse, which is the opposite of the intent.
          #
          # Log and verdict are separate rules throughout, for the reason
          # forward_blocklists documents: a limit on the verdict rule would let
          # packets over the rate escape the drop.
          ${lib.optionalString cfg.lowTrust.cdnQuota.enable ''
            # Volume quota for CDN space. Shapes, never drops.
            #
            # Domain fronting cannot be answered by address or by name: the edge
            # is shared with everything legitimate the house does, and the cover
            # name is never resolved so no DNS rule sees it. Volume is what
            # separates the two, by more than an order of magnitude —
            # custom-cdn-quota-asns.txt carries the measurements.
            #
            # `limit rate over` MATCHES when the bucket is empty, so under budget
            # these rules do not fire at all and the traffic is untouched. Over
            # it, every further packet takes meta mark 0x2 — the mark
            # forward_throttle already uses — and lands in the existing HTB
            # throttle class. No new tc class, no new mark namespace.
            #
            # The throttled class is 100 kbit/s = 12.5 kB/s, comfortably above
            # the ${toString cfg.lowTrust.cdnQuota.bytesPerSecond} B/s refill.
            # A client that keeps pulling therefore stays over budget and stays
            # in the class, instead of oscillating in and out of it. That is
            # deliberate: it is what makes this stable without any hysteresis.
            #
            # Written per-second because this kernel REJECTS the natural form:
            #   limit rate over 20 mbytes/hour
            #   -> Error: Could not process rule: Value too large for defined data type
            # Byte-unit rates overflow on /hour. /second and /minute are fine.
            #
            # The `add @cdn_throttled*` statement on each rule is placed after
            # the rate expression and before the counter, so it runs on exactly
            # the packets that take the mark. Device first, peer second in
            # every key: on the upload rules the device is saddr, on the
            # download rules it is daddr, and getting that the wrong way round
            # would put a badge on the wrong half of the page rather than
            # produce any visible error.
            chain lowtrust_cdn_quota {
              oifname "${cfg.ppp}" ip daddr @cdn_quota4 update @cdn_over4 { ip saddr limit rate over ${toString cfg.lowTrust.cdnQuota.bytesPerSecond} bytes/second burst ${cfg.lowTrust.cdnQuota.burst} } add @cdn_throttled4 { ip saddr . ip daddr } counter meta mark set 0x2 comment "CDN volume quota exceeded (upload, IPv4)"
              oifname "${cfg.lan0}" ip saddr @cdn_quota4 update @cdn_over4 { ip daddr limit rate over ${toString cfg.lowTrust.cdnQuota.bytesPerSecond} bytes/second burst ${cfg.lowTrust.cdnQuota.burst} } add @cdn_throttled4 { ip daddr . ip saddr } counter meta mark set 0x2 comment "CDN volume quota exceeded (download, IPv4)"
              oifname "${cfg.ppp}" ip6 daddr @cdn_quota6 update @cdn_over6 { ip6 saddr limit rate over ${toString cfg.lowTrust.cdnQuota.bytesPerSecond} bytes/second burst ${cfg.lowTrust.cdnQuota.burst} } add @cdn_throttled6 { ip6 saddr . ip6 daddr } counter meta mark set 0x2 comment "CDN volume quota exceeded (upload, IPv6)"
              oifname "${cfg.lan0}" ip6 saddr @cdn_quota6 update @cdn_over6 { ip6 daddr limit rate over ${toString cfg.lowTrust.cdnQuota.bytesPerSecond} bytes/second burst ${cfg.lowTrust.cdnQuota.burst} } add @cdn_throttled6 { ip6 daddr . ip6 saddr } counter meta mark set 0x2 comment "CDN volume quota exceeded (download, IPv6)"
            }
          ''}

          chain lowtrust_policy {
            # The pool is IPv4-only on the way out. Everything else in this
            # chain is a specific drop against a general accept; this one is the
            # reverse, and it is first because it makes every v6 rule below it
            # unreachable for pool devices. They are kept anyway: they cost
            # nothing, and they stay correct if this rule is ever narrowed.
            #
            # A drop, not a withheld address. RA is multicast to ff02::1, so
            # there is no per-MAC way to stop a device configuring itself —
            # that would take a separate VLAN, and the pool is dynamic (the
            # `lowtrust` CLI and the sops MAC list move devices in and out
            # between rebuilds), so no VLAN could track it. The device gets a
            # global address and simply cannot route it off the LAN.
            #
            # reject rather than drop, which is the opposite of every other
            # verdict here, for a reason specific to dual-stack: the device
            # still tries v6 first, and Happy Eyeballs only falls back to v4
            # after a timeout. An admin-prohibited turns that timeout into an
            # immediate failover, so the visible cost is nothing rather than a
            # stall on every new connection. There is no concealment to lose —
            # a device that cannot reach anything over v6 has already learnt
            # that from the first drop.
            #
            # Scoped LAN -> WAN like the rest of the chain, so v6 between LAN
            # devices still works. Nothing is gained by breaking it: those same
            # devices can reach each other over v4 regardless.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta nfproto ipv6 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust IPv6 rejects"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta nfproto ipv6 counter reject with icmpv6 type admin-prohibited comment "low-trust device: IPv4 only"

            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust port drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports counter drop comment "low-trust port drop"

            # QUIC. Written as its own rule rather than by putting 443 in
            # custom-lowtrust-ports.txt, and the distinction is the whole point:
            # that set is matched with `meta l4proto { tcp, udp }`, so 443 there
            # would take TCP 443 with it and leave the device with no HTTPS at
            # all.
            #
            # Cheap because QUIC degrades rather than fails. A browser or app
            # that cannot reach UDP 443 falls back to TCP 443 on its own — that
            # fallback is built into every QUIC implementation precisely because
            # middleboxes block it — so the visible cost is a slower handshake,
            # not a broken page.
            #
            # Worth taking because the 2026-08-13 captures show this client
            # using QUIC as a tunnel transport, on 443 and on high ports, and on
            # port 22 as well. Over UDP it is opaque from the first byte, where
            # the TCP fallback at least exposes a TLS ClientHello and an SNI to
            # look at. Forcing the fallback trades the device nothing and buys
            # back visibility.
            #
            # STUN ON 443 IS EXEMPTED, and the "degrades rather than fails"
            # argument above is exactly why it has to be. That argument is about
            # HTTP/3, which has a TCP sibling to fall back to. STUN has none:
            # udp/443 is a deliberate NAT-traversal port, offered precisely
            # because middleboxes pass 443 when they pass nothing else, and a
            # drop there is a hard failure with no fallback path.
            #
            # The 2026-08-16 baseline capture of a working Comera call is the
            # evidence. Throughout the call the client sends a STUN Binding
            # Request every 10s from its media socket to the same server address
            # on udp/3478 AND udp/443, as a pair, and both are answered. This
            # rule as written killed exactly the 443 half of every pair. It was
            # also the ONLY rule in this chain that the call touched — none of
            # its three destinations are in lowtrust_asn4, lowtrust_block4,
            # lowtrust_stun4, local_block4 or remote_block4, and none of its
            # ports are in lowtrust_ports.
            #
            # Matched by signature rather than by carving out Comera's addresses
            # because the addresses are AWS and rotate, and because Botim and
            # GoChat — the other two apps custom-lowtrust-stun-hosts.txt says
            # must keep working — traverse the same way. The offset expression
            # is the one already proven in the qos-mark chain: the STUN magic
            # cookie, four bytes into the UDP payload.
            #
            # Written as one inverted match rather than an accept placed ahead
            # of the drop, on purpose. An `accept` here would return from the
            # whole hook and let a pool device reach anything in lowtrust_asn4
            # or lowtrust_block4 by shaping its first eight bytes like STUN; a
            # `return` would skip the rest of this chain for the same packet
            # and leak the same way, only more quietly. Inverted, a STUN packet
            # simply does not match this rule and falls through to the provider
            # and subnet drops below, which still apply to it in full.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 443 @th,96,32 != 0x2112a442 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust QUIC drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 443 @th,96,32 != 0x2112a442 counter drop comment "low-trust QUIC drop (STUN on 443 exempted)"

            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust subnet drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 counter drop comment "low-trust subnet drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_block6 counter drop comment "low-trust subnet drop (IPv6)"

            # The carve-out from the provider block below. Placed HERE, and the
            # position is the whole design:
            #
            #   * after the port drops, the IPv6 reject and the QUIC drop, so an
            #     allowed destination is still held to all of those;
            #   * after the hand-written subnet drops, so an entry in
            #     custom-lowtrust-subnets.txt still beats one in
            #     custom-lowtrust-allow-subnets.txt — the hand-written block is
            #     the more specific statement of intent;
            #   * before the provider drops, which is the only thing it is meant
            #     to override.
            #
            # `return` and not `accept`. Both would do here, because
            # forward_lowtrust is a base chain of its own and an accept in it
            # would not spare the packet from forward_blocklists at the same
            # hook — custom-ip-blocklist.txt and the throttle list keep applying
            # either way. return is still the honest verb: it says "this chain
            # has nothing further to say about this packet", which is exactly
            # true, and it does not read as a grant of passage to someone
            # skimming for how a pool device could get out.
            #
            # What it skips inside this chain is the provider drops and the
            # generic-STUN drop under them. The latter is harmless to skip: that
            # rule is address-scoped to the three names in
            # custom-lowtrust-stun-hosts.txt, which are Google, Nextcloud and
            # BlackBerry, and are disjoint from anything that will ever be in
            # the allow list.
            #
            # Counted so the file above can be audited. A zero counter means
            # every range in custom-lowtrust-allow-subnets.txt has gone stale —
            # the same reasoning default.nix gives for counting its STUN
            # signature match, and the same failure mode: a rule that has
            # quietly stopped matching looks identical to one nobody needed.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_allow4 counter return comment "low-trust provider carve-out (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_allow6 counter return comment "low-trust provider carve-out (IPv6)"

            # Whole hosting networks. Its own log prefix rather than sharing
            # nft-block-lowtrust with the rules above: this pair is the one
            # likeliest to break something legitimate on a pool device, and when
            # that happens the question is "was it the provider block" — which a
            # shared prefix cannot answer.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_asn4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust-asn " comment "sample low-trust provider drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_asn4 counter drop comment "low-trust provider drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_asn6 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust-asn " comment "sample low-trust provider drops (IPv6)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_asn6 counter drop comment "low-trust provider drop (IPv6)"

            # Generic public STUN servers only, and only on the STUN ports — see
            # custom-lowtrust-stun-hosts.txt for why signature matching and
            # whole-address blocking were both rejected. stun.l.google.com's
            # addresses are shared with unrelated Google services, so this must
            # stay port-scoped rather than becoming an address block.
            #
            # 443 joined the port list when the QUIC drop above stopped covering
            # STUN. Until then this list could end at the three STUN ports,
            # because anything a tunnel client aimed at udp/443 died in that rule
            # regardless of address; exempting the signature there reopened
            # generic discovery on 443 for exactly the three servers this set
            # exists to deny. Adding the port closes it with no new collateral:
            # the match is still address-scoped to those three names, so an app's
            # own STUN and TURN on 443 — the case the exemption was written for —
            # is untouched.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 443, 3478, 5349, 19302 } ip daddr @lowtrust_stun4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust STUN drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 443, 3478, 5349, 19302 } ip daddr @lowtrust_stun4 counter drop comment "low-trust public STUN drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 443, 3478, 5349, 19302 } ip6 daddr @lowtrust_stun6 counter drop comment "low-trust public STUN drop (IPv6)"
          }
        ''}

        chain output_blocklists {
          type filter hook output priority -10; policy accept;

          # Blocks the router itself from reaching listed IPs
          ip daddr @remote_block4 drop comment "block router IPv4 destinations"
          ip6 daddr @remote_block6 drop comment "block router IPv6 destinations"
          ip daddr @local_block4 drop comment "block router IPv4 destinations (local list)"
          ip6 daddr @local_block6 drop comment "block router IPv6 destinations (local list)"
        }

        # drop traffic from listed IPs:
        chain input_blocklists {
          type filter hook input priority -10; policy accept;
          ip saddr @remote_block4 drop
          ip6 saddr @remote_block6 drop
          ip saddr @local_block4 drop
          ip6 saddr @local_block6 drop
        }
      '';
    };

    systemd.services.nft-blocklists-restore = {
      description = "Restore cached nftables blocklists";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      # See nftRulesetTrigger. Without it a ruleset reload leaves the cached
      # feed blocklists empty until the update timer next fires, which is up to
      # 12 minutes away and only helps if a download succeeds.
      restartTriggers = nftRulesetTrigger;

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nft-blocklists";
      };

      path = [
        pkgs.nftables
        pkgs.coreutils
      ];

      script = ''
        set -euo pipefail

        if [ -s "$STATE_DIRECTORY/ip-blocklists.nft" ]; then
          nft -f "$STATE_DIRECTORY/ip-blocklists.nft"
        fi
      '';
    };

    # Applies custom-ip-blocklist.txt and custom-port-blocklist.txt during
    # `nixos-rebuild switch`, so a change to either takes effect with the rebuild
    # instead of whenever the feed timer next happens to fire (up to 12 minutes
    # later, and only if a download succeeds).
    #
    # The trigger for that is the store paths of ${localBlocklist} and
    # ${portBlocklist} embedded in the script below: edit either txt and that
    # path changes, which changes this unit, which makes switch-to-configuration
    # restart it. That covers a list edit on its own, which is why this unit
    # carried no restartTriggers for so long — but it covers ONLY a list edit,
    # and a ruleset change that touches no list flushes these same sets while
    # leaving this unit's definition identical. That is the gap nftRulesetTrigger
    # closes; it is a second mechanism, not a replacement for this one.
    #
    # Note either way that restartTriggers alone would not be enough here,
    # because
    # switch-to-configuration only considers *active* units for restart, and a
    # plain oneshot is inactive the moment it exits. RemainAfterExit is what
    # keeps it active and therefore restartable. It is safe here precisely
    # because nothing else starts this unit: on the feed service it would be a
    # bug, since systemd treats `start` on an already-active oneshot as a no-op
    # and the timer would silently stop refreshing.
    systemd.services.nft-blocklists-local = {
      description = "Apply local nftables IP and port blocklists";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      # nftables.service recreates the table with empty sets when it restarts,
      # which would silently drop these entries until the next rebuild.
      partOf = [ "nftables.service" ];
      # partOf covers the restart. It does not cover the reload, which is how a
      # ruleset change is actually applied and which empties the same sets — see
      # nftRulesetTrigger for the outage that came of trusting partOf alone.
      restartTriggers = nftRulesetTrigger;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [ pkgs.nftables ];

      # imo's own lists are deliberately absent: which of its two set pairs is
      # populated depends on the day, so it is imo-policy.service that writes
      # them and this unit that pulls it. One writer per set.
      script = ''
        set -euo pipefail
        nft -f ${localBlocklist}
        nft -f ${portBlocklist}
        nft -f ${throttleList}
        ${lib.optionalString cfg.lowTrust.enable ''
          nft -f ${lowTrustPorts}
          nft -f ${lowTrustSubnets}
          # Before the ASN list, so that on a reload the carve-out is never
          # observably absent while the provider ranges it exempts are already
          # loaded. Each nft -f is its own transaction, so the window between
          # two of them is real; this order makes it fail safe rather than
          # briefly cutting Botim off on every rebuild.
          nft -f ${lowTrustAllow}
          nft -f ${lowTrustASNs}
          ${lib.optionalString cfg.lowTrust.cdnQuota.enable ''
            nft -f ${cdnQuotaASNs}
          ''}
        ''}
      '';
    };

    # Loads the permanent pool membership from the sops secret. A service
    # rather than a generated .nft file because the list must not reach the Nix
    # store: it names people's devices and this repository is public.
    #
    # partOf nftables.service for the same reason nft-blocklists-local is —
    # a ruleset reload recreates the table with empty sets, which would
    # silently empty the pool until the next rebuild.
    #
    # That comment was right about the consequence and wrong about the cover:
    # partOf does not fire on a reload at all, and this unit was one of the
    # three left stale through the 2026-08-15 outage. restartTriggers below is
    # what actually holds it.
    systemd.services.nft-lowtrust-macs = lib.mkIf cfg.lowTrust.enable {
      description = "Load low-trust pool MAC addresses";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      partOf = [ "nftables.service" ];
      restartTriggers = nftRulesetTrigger;

      # The script below exits 1 on a missing or malformed file, and that is
      # the intended behaviour — but without a retry it is permanent. The
      # realistic cause is ordering at boot: this reads a sops secret, and a
      # unit that runs before sops-install-secrets has decrypted it sees no
      # file, fails, and then sits failed with RemainAfterExit keeping it that
      # way. An empty pool is a fail-open for every low-trust rule, so waiting
      # for a human to notice is the wrong outcome for a race that resolves
      # itself in seconds.
      #
      # Malformed content, by contrast, never fixes itself — hence the same
      # bounded start limit as the STUN unit. It retries through the race and
      # then stays failed and visible rather than looping on a bad file.
      startLimitIntervalSec = 600;
      startLimitBurst = 6;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
      };

      path = with pkgs; [
        nftables
        gnugrep
        gnused
        coreutils
      ];

      # Fails loudly on a missing or malformed file rather than loading an
      # empty set. The plaintext lists get a build-time parse that fails the
      # rebuild on a typo; a runtime secret cannot, so a failed unit is the
      # substitute for that guarantee. An empty pool is a silent fail-open.
      script = ''
        set -euo pipefail

        file=${lib.escapeShellArg (toString cfg.lowTrust.macFile)}

        if [ ! -r "$file" ]; then
          echo "nft-lowtrust-macs: cannot read $file" >&2
          exit 1
        fi

        elements=""
        while IFS= read -r line || [ -n "$line" ]; do
          line=''${line%%#*}
          line=$(printf '%s' "$line" | tr -d '[:space:]' | tr 'A-F' 'a-f')
          [ -z "$line" ] && continue
          if ! printf '%s' "$line" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
            echo "nft-lowtrust-macs: malformed MAC address: $line" >&2
            exit 1
          fi
          elements="$elements$line, "
        done < "$file"

        # Both tables, because the sets are declared in both and nftables has
        # no way to share one. Missing the second is the failure mode this
        # whole plan keeps warning about: the ruleset builds, and qos-mark
        # fails to load at runtime.
        for table in router-blocklists router-filter; do
          nft flush set inet "$table" lowtrust_macs
          if [ -n "$elements" ]; then
            nft add element inet "$table" lowtrust_macs "{ ''${elements%, } }"
          fi
        done
      '';
    };

    # Resolves the public STUN server names into the drop sets. A timer rather
    # than a build-time resolution because those addresses move, and a stale
    # entry is a silently open hole rather than a visible failure.
    #
    # Deliberately tolerant where the MAC loader is strict: a name that fails to
    # resolve is skipped with a warning rather than failing the unit. The
    # failure mode differs — an unresolvable name leaves one STUN server
    # reachable, where an unreadable MAC file would empty the whole pool.
    systemd.services.nft-lowtrust-stun = lib.mkIf cfg.lowTrust.enable {
      description = "Resolve public STUN servers into the low-trust drop sets";
      after = [
        "nftables.service"
        "nft-blocklists-local.service"
        "network-online.target"
        # The resolver this unit exists to ask. Ordering only binds inside a
        # transaction, so this does not protect the timer-driven runs — but a
        # `nixos-rebuild switch` that changes the DNS config restarts blocky
        # and pulls this unit through nft-blocklists-local in the same
        # transaction, and without this the two raced. On 2026-08-15 that race
        # landed one second apart: the switch at 21:40:01, every lookup empty
        # at 21:40:02, and a recovery on the 30-second retry.
        "blocky.service"
      ];
      wants = [
        "nftables.service"
        "network-online.target"
        "blocky.service"
      ];
      partOf = [ "nftables.service" ];
      wantedBy = [
        "multi-user.target"
        "nft-blocklists-local.service"
      ];

      # RemainAfterExit deliberately false, unlike nft-lowtrust-macs. systemd
      # treats `start` on an already-active oneshot as a no-op, so leaving this
      # one active would quietly stop the timer from ever re-resolving — the
      # exact trap imo-policy is commented against.
      #
      # That choice costs the obvious way of surviving a ruleset reload, which
      # recreates the table with empty sets. partOf does not cover it: systemd
      # propagates a partOf restart as a *try*-restart, and a try-restart on an
      # inactive unit is a no-op — and with RemainAfterExit false this unit is
      # inactive the moment it exits. wantedBy multi-user.target only fires at
      # boot. So without the indirection below, every `nixos-rebuild switch`
      # that touches the ruleset would leave lowtrust_stun4/6 empty for up to an
      # hour, until the timer next elapsed: a silent fail-open, the thing this
      # whole unit is written to avoid. nft-lowtrust-macs is unaffected only
      # because RemainAfterExit true keeps it active and therefore restartable.
      #
      # The fix is the one imo-policy uses: hang off nft-blocklists-local, which
      # is RemainAfterExit true and partOf nftables.service. It receives the
      # propagated restart and pulls this oneshot along with it.
      # Restart=on-failure because the thing this unit depends on — DNS — is
      # the thing most likely to be briefly unavailable, and the timer below
      # is an HOUR apart. Without a retry, a resolver that is down for the ten
      # seconds this unit happens to run leaves the sets stale until the next
      # elapse, which is the longest-lived hole in the whole low-trust setup.
      #
      # Valid on a oneshot: systemd rejects only Restart=always and
      # Restart=on-success for Type=oneshot, precisely because a oneshot exits
      # cleanly by design. on-failure is the supported case.
      #
      # THE START LIMIT IS THE POINT OF THE PAIR, not boilerplate. Left
      # unbounded this would retry every 30s forever if the failure were
      # permanent rather than transient — someone adding stun.l.google.com to
      # custom-blocklist.txt would do it, since then no name resolves and the
      # check at the end of the script fails every time. Six tries in ten
      # minutes covers any plausible resolver blip, and then the unit stays
      # failed and VISIBLE in systemctl instead of spinning. The hourly timer
      # still runs after the window rolls, so a longer outage recovers on its
      # own; it just stops pretending a permanent fault is a transient one.
      startLimitIntervalSec = 600;
      startLimitBurst = 6;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        Restart = "on-failure";
        RestartSec = 30;
      };

      path = with pkgs; [
        nftables
        dnsutils
        gnugrep
        gnused
        coreutils
      ];

      script = ''
        set -euo pipefail

        v4=""
        v6=""
        anyresolved=""
        while IFS= read -r line || [ -n "$line" ]; do
          name=''${line%%#*}
          name=$(printf '%s' "$name" | tr -d '[:space:]')
          [ -z "$name" ] && continue

          # The sinkhole answers are rejected explicitly, and this is not a
          # theoretical guard: two of the three names in this file are ALSO
          # blocked by name in custom-blocklist.txt, and this service resolves
          # through blocky like everything else on the router. So `dig` hands
          # back 0.0.0.0 and :: for them, both of which are perfectly valid
          # addresses to the filters below — without this the set would fill
          # with sinkhole placeholders and the rule would match nothing while
          # looking populated. That is worse than an empty set, which at least
          # reads as broken.
          #
          # A name that only ever returns the sinkhole is reported as
          # unresolved, because from this service's point of view it is: the
          # address it needs is not obtainable here. The block still holds — by
          # name for every device, and by address in custom-ip-blocklist.txt for
          # the two that were resolved from upstream by hand.
          got=""
          for addr in $(dig +short +timeout=3 +tries=2 "$name" A 2>/dev/null || true); do
            case "$addr" in
              *[!0-9.]*) continue ;;
              # A sinkhole answer is still an answer, and that distinction is
              # the whole point of tracking it: it proves the resolver is up
              # even though this name yielded nothing usable. See the guard at
              # the end.
              0.0.0.0) answered=yes ; continue ;;
            esac
            v4="$v4$addr, "
            got=yes
            answered=yes
          done
          # The character-class reject on the FIRST line of each case is load
          # bearing and the two must stay symmetrical. `dig` prints
          # ";; communications error to 127.0.0.1#53: timed out" on STDOUT as
          # well as stderr, so the 2>/dev/null above does not keep it out of
          # this loop and word-splitting hands each piece of it here as an
          # "address".
          #
          # This bit the v6 branch on bongo, 2026-08-14 15:40: the resolver was
          # briefly unreachable, and the branch tested only for a colon
          # (*:*), which "127.0.0.1#53:" satisfies. Six of those — three names
          # times +tries=2 — reached nft as set elements and it exited 1 on a
          # syntax error. The v4 branch shrugged the same run off, because it
          # validates the whole token rather than looking for one character.
          #
          # It was worse than a failed unit. The flush below runs BEFORE the
          # add, so the flush succeeded, the add failed, set -e aborted, and
          # lowtrust_stun6 was left EMPTY — exactly the fail-open the comment
          # under it says must never happen. A junk-but-non-empty $v6 walks
          # straight past the "resolved nothing, keep what we have" guard,
          # because that guard tests for emptiness and junk is not empty.
          for addr in $(dig +short +timeout=3 +tries=2 "$name" AAAA 2>/dev/null || true); do
            case "$addr" in
              *[!0-9A-Fa-f:]*) continue ;;
              ::) answered=yes ; continue ;;
              *:*) v6="$v6$addr, " ; got=yes ; answered=yes ;;
            esac
          done

          [ -z "$got" ] && echo "nft-lowtrust-stun: could not resolve $name (sinkholed here, or genuinely unresolvable)" >&2
          [ -n "$got" ] && anyresolved=yes
        done < ${./custom-lowtrust-stun-hosts.txt}

        # Flush is conditional per family, not unconditional the way the MAC
        # loader's is. An empty set is a silent fail-open — every device in
        # the pool gets a free pass to the STUN servers until the next timer
        # fires, up to an hour away — while a stale set is a small, bounded
        # hole (an address that has since moved). So a run that resolves
        # nothing for a family must leave that family's set exactly as it
        # was, not clear it. Decided per family rather than "both or
        # neither" so a v6-less run (common — not every network here has
        # working IPv6) does not throw away working v4 entries, and vice
        # versa.
        # FLUSH AND ADD GO IN AS ONE `nft -f` TRANSACTION, for the reason the
        # imo policy generator above already gives at its own flush pair: nft
        # applies a -f script atomically, so the set is never observably empty
        # between the two.
        #
        # Two separate nft calls is what turned the 2026-08-14 15:40 failure on
        # bongo from a failed unit into a fail-open. The flush landed, the add
        # was rejected, set -e ended the run, and lowtrust_stun6 sat empty until
        # the next timer — the precise outcome the paragraph above forbids. The
        # emptiness guard cannot catch that on its own, because it runs before
        # nft ever sees the elements and a malformed list is not an empty one.
        # With one transaction a rejected add takes the flush down with it and
        # the previous contents survive, whatever got past the filters.
        if [ -n "$v4" ]; then
          printf 'flush set inet router-blocklists lowtrust_stun4\nadd element inet router-blocklists lowtrust_stun4 { %s }\n' "''${v4%, }" | nft -f -
        else
          echo "nft-lowtrust-stun: no IPv4 addresses resolved this run, keeping previous lowtrust_stun4 contents" >&2
        fi
        if [ -n "$v6" ]; then
          printf 'flush set inet router-blocklists lowtrust_stun6\nadd element inet router-blocklists lowtrust_stun6 { %s }\n' "''${v6%, }" | nft -f -
        else
          echo "nft-lowtrust-stun: no IPv6 addresses resolved this run, keeping previous lowtrust_stun6 contents" >&2
        fi

        # NOTHING RESOLVED AT ALL IS A FAILURE, and it has to be, because the
        # guards above are deliberately quiet: they keep the previous contents
        # and exit 0, so a resolver outage otherwise leaves the sets to go stale
        # for a full hour with nothing but two log lines to show for it.
        # Exiting non-zero is what hands the problem to Restart=on-failure on
        # the unit, which retries in 30s instead of waiting for the timer.
        #
        # THE TEST IS "no name resolved", NOT "a family is empty", and the
        # difference is the whole correctness of this check:
        #
        #   * Two of the three names in custom-lowtrust-stun-hosts.txt are
        #     sinkholed by blocky on this router BY DESIGN, so "could not
        #     resolve" for them is the healthy case and appears every run.
        #     stun.l.google.com is not sinkholed, so a working resolver always
        #     yields at least one address.
        #   * An empty v6 with a non-empty v4 is ordinary — the comment above
        #     notes a v6-less run is common here. Failing on that would retry
        #     forever on a network that simply has no IPv6.
        #
        # So this fires only when every lookup came back empty. What that
        # MEANS is then decided by $answered, which is set whenever the
        # resolver returned anything at all — including the 0.0.0.0 and :: the
        # loops above discard. The two cases need different words because they
        # need different actions, and the version of this check that had only
        # one message asserted "resolver is probably down" on evidence that
        # could equally mean "every name is blocked here":
        #
        #   * Nothing answered: the resolver is genuinely unreachable. A
        #     restart of blocky is the common cause and lasts a second, so the
        #     retry is the fix and the start limit bounds it.
        #   * Something answered, but only sinkholes: the resolver is up and
        #     every name in the list is blocked on this router. No amount of
        #     retrying changes that. It still exits 1, deliberately — the sets
        #     keep their previous contents and someone needs to know the list
        #     has stopped feeding them — and the start limit is what stops it
        #     retrying forever.
        if [ -z "$anyresolved" ]; then
          if [ -n "''${answered:-}" ]; then
            echo "nft-lowtrust-stun: every name in the list is sinkholed here — the resolver answered, so this is the blocklist shadowing the STUN list, not an outage; sets keep their previous contents" >&2
          else
            echo "nft-lowtrust-stun: no answer for any name — the resolver is down; failing so systemd retries" >&2
          fi
          exit 1
        fi
      '';
    };

    systemd.timers.nft-lowtrust-stun = lib.mkIf cfg.lowTrust.enable {
      description = "Refresh low-trust public STUN addresses";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
    };

    # Applies whichever of the two imo states is in force. Everything about
    # this is arranged so the policy cannot be silently lost, because the state
    # it maintains lives only in the kernel:
    #
    #   * boot — wantedBy multi-user.target, ordered after nftables;
    #   * ruleset reload, which recreates the table with empty sets —
    #     nft-blocklists-local is partOf nftables.service, so a reload restarts
    #     it and it pulls this unit along;
    #   * a midnight missed while the router was off — Persistent on the timer
    #     below.
    #
    # RemainAfterExit is deliberately false, unlike nft-blocklists-local:
    # systemd treats `start` on an already-active oneshot as a no-op, so
    # leaving this one active would quietly stop the timer from ever
    # re-applying it. It is the trap nft-blocklists-update is commented against
    # above, and it matters more here, where the whole unit exists to be re-run.
    systemd.services.imo-policy = {
      description = "Apply today's imo policy (block or throttle)";
      wantedBy = [
        "multi-user.target"
        "nft-blocklists-local.service"
      ];
      after = [
        "nftables.service"
        "nft-blocklists-local.service"
      ];
      wants = [ "nftables.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };

      path = [
        pkgs.nftables
        imoPolicyToday
      ];

      script = ''
        set -euo pipefail

        mode=$(imo-policy-today)

        case "$mode" in
          block)
            nft -f ${imoBlockState}
            ;;
          throttle)
            nft -f ${imoThrottleState}
            ;;
          *)
            # Unreachable unless imo-policy-today is changed and this is not.
            # Failing loudly beats leaving the sets at yesterday's contents,
            # which would look like a working policy for a whole day.
            echo "imo-policy: unexpected mode from imo-policy-today: $mode" >&2
            exit 1
            ;;
        esac

        echo "imo-policy: $mode" >&2
      '';
    };

    systemd.timers.imo-policy = {
      description = "Re-evaluate the imo policy at the start of each day";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Local midnight — the routers run Asia/Dubai, and both this and the
        # `date +%d` in imo-policy-today are local time, so the flip lands
        # where a calendar says it should.
        OnCalendar = "*-*-* 00:00:00";
        Persistent = true;
      };
    };

    # Exposed so the schedule can be checked for any date without waiting for
    # it, e.g. `imo-policy-today 12`.
    environment.systemPackages = [ imoPolicyToday ];

    systemd.services.nft-blocklists-update = {
      description = "Download and apply nftables blocklists";
      after = [
        "network-online.target"
        "nftables.service"
        "nft-blocklists-restore.service"
      ];
      wants = [ "network-online.target" ];

      # Downloads over the WAN, so a transient failure — DNS, a dead upstream,
      # a PPP session that has not come back yet — is the expected failure and
      # not an exceptional one. Cheaper here than on the two units above,
      # because this timer is 10 minutes rather than an hour and the previous
      # ruleset stays loaded meanwhile, so the exposure is a stale list rather
      # than an empty one. The retry just stops a blip costing a full cycle.
      #
      # Burst 3 and not 6: each attempt pulls several upstream lists, so a
      # tight retry loop on a genuinely dead upstream is rude to it as well as
      # pointless. Three tries a minute apart, then leave it to the timer.
      startLimitIntervalSec = 600;
      startLimitBurst = 3;

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nft-blocklists";
        Restart = "on-failure";
        RestartSec = 60;
      };

      path = [
        pkgs.curl
        pkgs.python3
        pkgs.nftables
        pkgs.coreutils
      ];

      script = ''
        set -euo pipefail

        downloads="$(mktemp -d)"
        tmpnft="$(mktemp)"
        alltxt="$(mktemp)"
        trap 'rm -rf "$downloads"; rm -f "$tmpnft" "$alltxt"' EXIT

        : > "$tmpnft"
        : > "$alltxt"
        ok=0
        failed=0

        ${lib.concatMapStringsSep "\n" (feed: ''
          feedtxt="$(mktemp)"
          : > "$feedtxt"
          feedok=0
          ${lib.concatMapStringsSep "\n" (url: ''
            if curl --fail --silent --show-error --location \
                 "${url}" \
                 -o "$downloads/${builtins.hashString "sha256" url}.txt"; then
              cat "$downloads/${builtins.hashString "sha256" url}.txt" >> "$feedtxt"
              printf '\n' >> "$feedtxt"
              ok=$((ok + 1))
              feedok=$((feedok + 1))
            else
              failed=$((failed + 1))
              echo "nft-blocklists-update: feed download failed, skipping: ${url}" >&2
            fi
          '') feed.urls}
          ${lib.concatMapStringsSep "\n" (file: ''
            cat "${file}" >> "$feedtxt"
            printf '\n' >> "$feedtxt"
            ok=$((ok + 1))
            feedok=$((feedok + 1))
          '') (feed.files or [ ])}

          # Only rebuild this feed's sets if at least one source was loaded;
          # otherwise leave the sets at their cached values.
          if [ "$feedok" -gt 0 ]; then

          python3 - "$feedtxt" "$tmpnft" "${feed.set4}" "${feed.set6}" "${toString feed.minEntries}" <<'PY'
          import ipaddress
          import pathlib
          import sys

          src = pathlib.Path(sys.argv[1])
          dst = pathlib.Path(sys.argv[2])
          set4 = sys.argv[3]
          set6 = sys.argv[4]
          min_entries = int(sys.argv[5])

          allow4 = set(filter(None, """${lib.concatStringsSep "\n" allow4}""".splitlines()))
          allow6 = set(filter(None, """${lib.concatStringsSep "\n" allow6}""".splitlines()))

          v4 = []
          v6 = []
          seen4 = set()
          seen6 = set()

          for line in src.read_text().splitlines():
              s = line.split("#", 1)[0].strip()
              if not s:
                  continue
              try:
                  net = ipaddress.ip_network(s, strict=False)
              except ValueError:
                  continue

              if net.version == 4:
                  net_str = str(net)
                  if net_str not in allow4 and net_str not in seen4:
                      seen4.add(net_str)
                      v4.append(net_str)
              else:
                  net_str = str(net)
                  if net_str not in allow6 and net_str not in seen6:
                      seen6.add(net_str)
                      v6.append(net_str)

          # Sanity guard: refuse obviously broken / truncated downloads
          if len(v4) + len(v6) < min_entries:
              raise SystemExit(f"refusing suspiciously small blocklist for {set4}/{set6}")

          # Interval sets reject overlapping elements. VPN feeds contain CIDRs
          # which can cover individual addresses or narrower prefixes from the
          # other feeds, so collapse each family before generating nft syntax.
          v4 = [str(net) for net in ipaddress.collapse_addresses(
              ipaddress.ip_network(value) for value in v4
          )]
          v6 = [str(net) for net in ipaddress.collapse_addresses(
              ipaddress.ip_network(value) for value in v6
          )]

          with dst.open("a") as f:
              f.write(f"flush set inet router-blocklists {set4}\n")
              if v4:
                  f.write(f"add element inet router-blocklists {set4} {{\n")
                  for i, elem in enumerate(v4):
                      comma = "," if i + 1 < len(v4) else ""
                      f.write(f"  {elem}{comma}\n")
                  f.write("}\n")

              f.write(f"flush set inet router-blocklists {set6}\n")
              if v6:
                  f.write(f"add element inet router-blocklists {set6} {{\n")
                  for i, elem in enumerate(v6):
                      comma = "," if i + 1 < len(v6) else ""
                      f.write(f"  {elem}{comma}\n")
                  f.write("}\n")
          PY

          cat "$feedtxt" >> "$alltxt"
          else
            echo "nft-blocklists-update: no URLs downloaded for ${feed.set4}/${feed.set6}, leaving sets unchanged" >&2
          fi
          rm -f "$feedtxt"
        '') feeds}

        if [ "$ok" -eq 0 ]; then
          echo "nft-blocklists-update: all $failed feed(s) failed to download, keeping cached blocklist" >&2
          exit 1
        fi
        if [ "$failed" -gt 0 ]; then
          echo "nft-blocklists-update: continuing with $ok of $((ok + failed)) feed(s)" >&2
        fi

        # Validate then apply atomically
        nft -c -f "$tmpnft"
        nft -f "$tmpnft"

        install -Dm0644 "$alltxt"  "$STATE_DIRECTORY/ip-blocklists.txt"
        install -Dm0644 "$tmpnft" "$STATE_DIRECTORY/ip-blocklists.nft"
      '';
    };

    systemd.timers.nft-blocklists-update = {
      description = "Periodic nftables blocklist refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "10min";
        RandomizedDelaySec = "2min";
        Persistent = true;
      };
    };
  };
}
