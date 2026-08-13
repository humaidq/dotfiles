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
          chain lowtrust_policy {
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust port drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport @lowtrust_ports counter drop comment "low-trust port drop"

            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust subnet drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip daddr @lowtrust_block4 counter drop comment "low-trust subnet drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" ip6 daddr @lowtrust_block6 counter drop comment "low-trust subnet drop (IPv6)"

            # Generic public STUN servers only, and only on the STUN ports — see
            # custom-lowtrust-stun-hosts.txt for why signature matching and
            # whole-address blocking were both rejected. stun.l.google.com's
            # addresses are shared with unrelated Google services, so this must
            # stay port-scoped rather than becoming an address block.
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip daddr @lowtrust_stun4 limit rate 60/minute burst 20 packets log prefix "nft-block-lowtrust " comment "sample low-trust STUN drops"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip daddr @lowtrust_stun4 counter drop comment "low-trust public STUN drop (IPv4)"
            iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 3478, 5349, 19302 } ip6 daddr @lowtrust_stun6 counter drop comment "low-trust public STUN drop (IPv6)"
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
    # The trigger is the store paths of ${localBlocklist} and ${portBlocklist}
    # embedded in the script below: edit either txt and that path changes, which
    # changes this unit, which makes switch-to-configuration restart it. No
    # restartTriggers needed — and
    # note that restartTriggers alone would not have worked here, because
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
    systemd.services.nft-lowtrust-macs = lib.mkIf cfg.lowTrust.enable {
      description = "Load low-trust pool MAC addresses";
      wantedBy = [ "multi-user.target" ];
      after = [ "nftables.service" ];
      wants = [ "nftables.service" ];
      partOf = [ "nftables.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
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
        "network-online.target"
      ];
      wants = [
        "nftables.service"
        "network-online.target"
      ];
      partOf = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];

      # RemainAfterExit deliberately false, unlike nft-lowtrust-macs. systemd
      # treats `start` on an already-active oneshot as a no-op, so leaving this
      # one active would quietly stop the timer from ever re-resolving — the
      # exact trap imo-policy is commented against. partOf still re-triggers it
      # on a ruleset reload through wantedBy.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
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
        while IFS= read -r line || [ -n "$line" ]; do
          name=''${line%%#*}
          name=$(printf '%s' "$name" | tr -d '[:space:]')
          [ -z "$name" ] && continue

          got=""
          for addr in $(dig +short +timeout=3 +tries=2 "$name" A 2>/dev/null || true); do
            case "$addr" in
              *[!0-9.]*) continue ;;
            esac
            v4="$v4$addr, "
            got=yes
          done
          for addr in $(dig +short +timeout=3 +tries=2 "$name" AAAA 2>/dev/null || true); do
            case "$addr" in
              *:*) v6="$v6$addr, " ; got=yes ;;
            esac
          done

          [ -z "$got" ] && echo "nft-lowtrust-stun: could not resolve $name" >&2
        done < ${./custom-lowtrust-stun-hosts.txt}

        nft flush set inet router-blocklists lowtrust_stun4
        nft flush set inet router-blocklists lowtrust_stun6
        if [ -n "$v4" ]; then
          nft add element inet router-blocklists lowtrust_stun4 "{ ''${v4%, } }"
        fi
        if [ -n "$v6" ]; then
          nft add element inet router-blocklists lowtrust_stun6 "{ ''${v6%, } }"
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

      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nft-blocklists";
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
