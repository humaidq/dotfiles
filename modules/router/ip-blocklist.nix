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
    # the txt free to list whatever is clearest — 169.136.141.0/24 from an
    # AS listing and the wider NETSTAR range that contains it, say — and
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

        # Populated from custom-port-blocklist.txt by nft-blocklists-local.
        # Plain set rather than an interval one: the entries are discrete ports,
        # and a range has never been needed. Adding `flags interval` later is a
        # one-line change if that stops being true.
        set blocked_ports {
          type inet_service
        }

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

          # Blocks LAN clients from reaching listed IPs
          ip daddr @remote_block4 counter drop comment "block forwarded IPv4 destinations"
          ip6 daddr @remote_block6 counter drop comment "block forwarded IPv6 destinations"
          ip daddr @local_block4 counter drop comment "block forwarded IPv4 destinations (local list)"
          ip6 daddr @local_block6 counter drop comment "block forwarded IPv6 destinations (local list)"
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

      script = ''
        set -euo pipefail
        nft -f ${localBlocklist}
        nft -f ${portBlocklist}
      '';
    };

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
