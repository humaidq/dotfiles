{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
  formatPorts = ports: lib.concatMapStringsSep ", " toString ports;
in
{
  imports = [
    ./dns.nix
    ./qos.nix
    ./qos-metrics.nix
    ./fullreboot.nix
    ./host-metrics.nix
    ./ntp.nix
    ./ont.nix
    ./pppd.nix
    ./client-mode.nix
    ./geoip.nix
    ./ip-blocklist.nix
    ./lists.nix
    ./suricata.nix
    ./tools.nix
    ./vpn.nix
    ./web.nix
  ];

  options.sifr.router = {
    enable = lib.mkEnableOption "router module";
    wan = lib.mkOption {
      type = lib.types.str;
      default = "enp1s0";
      description = "The WAN interface.";
    };
    lan0 = lib.mkOption {
      type = lib.types.str;
      default = "enp2s0";
      description = "The LAN0 interface.";
    };
    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.20.0.1/16";
      description = "The LAN address configured on the router interface.";
    };
    meshAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.10.0.18";
      description = ''
        Address on the mesh interface to serve the peers page from, without a
        prefix length. When null the peers routes are not served at all and
        router-web behaves exactly as it did before the feature existed.

        Deliberately explicit rather than resolved from the mesh interface at
        startup: the interface may not be up when router-web starts, and a
        service that sometimes fails to bind depending on start order is worse
        than one that is configured.
      '';
    };
    ppp = lib.mkOption {
      type = lib.types.str;
      default = "ppp0";
      description = "The PPP interface.";
    };
    pppMtu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1492;
      description = ''
        MTU of the PPPoE uplink. 1492 is 1500 minus the 8-byte PPPoE/PPP
        header, which is what this ISP gives; a line negotiating RFC 4638
        baby jumbo frames would be 1500.

        One number, three consumers, and they have to agree: pppd's own
        mtu/mru, the MSS clamp in both directions, and the MTU option in the
        LAN router advertisement. When they disagree the failure is a partial
        one — handshakes complete and small requests work, then anything that
        fills a segment disappears — so this is deliberately not three
        literals in three files.
      '';
    };
    localDomain = lib.mkOption {
      type = lib.types.str;
      default = "home.arpa";
      description = "Local DNS domain served by the router for DHCP hostnames.";
    };
    customDNSMappings = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      description = "Router-specific static DNS name-to-address mappings.";
    };
    meshDNSMappings = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      example = {
        "alq.ae" = "10.10.0.12";
      };
      description = ''
        The same names as customDNSMappings, answered differently for clients
        that arrive over the mesh interface. Split horizon, and it exists
        because the two sides of this router genuinely need different answers:
        the home server is 10.20.0.250 on the LAN and 10.10.0.12 on the
        overlay, and neither address is reachable from the other side —
        nothing bridges the LAN into nebula (see hosts/bongo/default.nix), so
        a roaming client handed the LAN address has nowhere to send the
        packet.

        Names not listed here are resolved for mesh clients exactly as they
        are for everyone else, blocklists included; only the listed ones are
        overridden. Names *under* a listed one that this router already
        answers specifically — the s.alq.ae mesh host records, the LAN's own
        DHCP zone — keep their existing answers rather than being swallowed by
        the wildcard.

        Requires sifr.router.meshAddress. Serving this needs a second resolver
        in front of blocky, because blocky cannot do it: its cache is keyed on
        name and type with no client component, so one name has exactly one
        answer per router no matter which client asked. See dns.nix.
      '';
    };
    pppdConfig = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the ISP provided credentials for PPPoE authentication.";
    };
    dhcp = {
      rangeStart = lib.mkOption {
        type = lib.types.str;
        default = "10.20.0.100";
        description = "Start of the DHCP lease range.";
      };
      rangeEnd = lib.mkOption {
        type = lib.types.str;
        default = "10.20.0.200";
        description = "End of the DHCP lease range.";
      };
      leaseTime = lib.mkOption {
        type = lib.types.str;
        default = "12h";
        description = "Default DHCP lease time.";
      };
      routerAddress = lib.mkOption {
        type = lib.types.str;
        default = "10.20.0.1";
        description = "Router address advertised over DHCP.";
      };
      dnsServer = lib.mkOption {
        type = lib.types.str;
        default = "10.20.0.1";
        description = "DNS server advertised over DHCP.";
      };
      leasesFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/dnsmasq/dnsmasq.leases";
        description = "Path to the dnsmasq DHCP leases file.";
      };
      hostsFile = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Optional path to a dnsmasq static DHCP hosts file.";
      };
    };
    # Applied to the addresses in custom-throttle-list.txt, in both directions.
    #
    # A BANDWIDTH CAP AND NOTHING ELSE, since 2026-08-13. This tier used to add
    # 400 ms of latency, 100 ms of jitter and 3% random loss on top of the cap,
    # on the theory that a tunnel which stays connected and is miserable beats
    # one that fails cleanly and makes the client reconnect elsewhere.
    #
    # Observation on the network says that backfired. The clients being shaped
    # score their candidate nodes on exactly those signals — RTT and loss — so
    # an impaired node is *easier* for them to detect and discard than a slow
    # one, and they simply moved on and found unthrottled candidates. Latency
    # and loss were doing the opposite of their purpose: advertising which nodes
    # had been touched.
    #
    # A pure rate cap is close to invisible to that scoring. A latency probe is
    # a couple of small packets and sails through under the cap, so the node
    # looks healthy and stays selected, while anything that actually moves data
    # crawls. Keeping the node attractive is the point.
    throttle = {
      rate = lib.mkOption {
        type = lib.types.str;
        default = "100kbit";
        description = "Rate cap applied to throttled addresses, each direction. The whole of the throttle: no added latency, jitter or loss.";
      };

      # The same argument as the paragraph above, carried one step further.
      #
      # A rate cap is invisible to a LATENCY probe, which is what the note above
      # says. It is NOT invisible to a THROUGHPUT probe, and the 2026-08-30
      # captures show this client running one: it opens every candidate node it
      # has been given, pushes a few KiB through each, ranks them, and selects.
      # A node capped from its first byte comes last in that ranking every time,
      # so the cap was still advertising which nodes had been touched — just via
      # a different measurement than the latency and loss that were removed on
      # 2026-08-13.
      #
      # A grace allowance closes that. Every device-and-peer pair gets this many
      # bytes at full speed before the cap engages, which is orders of magnitude
      # more than any probe and a rounding error against a tunnel session. The
      # node therefore measures FASTER than an untouched one during selection —
      # it is being probed at line rate — gets picked, and only then crawls. The
      # client has no signal to act on until it has already committed.
      #
      # 2 MB rather than something smaller because the probe traffic seen was a
      # few KiB per node and the reply payloads a few hundred bytes; anything in
      # that region risks catching a real selection round. Rather than something
      # larger because the allowance is per pair and the fleet is in the
      # hundreds, so it is also the per-node cost of letting the client shop.
      graceBytes = lib.mkOption {
        type = lib.types.str;
        default = "2 mbytes";
        description = ''
          Bytes each device-and-peer pair may move at full speed before the
          throttle tier engages, counted across both directions together.

          An nftables quota expression, so the units are nft's own ("2 mbytes",
          "512 kbytes"). Applies to every source of the 0x2 mark — the throttle
          list, the published node list and the low-trust provider ASNs alike.
        '';
      };
    };
    # What the addresses in custom-imo-list.txt get. The two sites want
    # different answers, hence a per-host option rather than a constant: one
    # refuses imo outright, the other alternates by day. See
    # docs/superpowers/specs/2026-08-11-imo-per-host-policy-design.md for why
    # only the IP tier alternates while the DNS and port layers stay closed on
    # both, and docs/superpowers/specs/2026-08-08-imo-throttle-tier-design.md
    # for how the throttle tier came to exist at all.
    imoPolicy = lib.mkOption {
      type = lib.types.enum [
        "throttle"
        "block"
        "alternate"
      ];
      default = "throttle";
      description = ''
        How the imo estate is treated on this router.

        "throttle" marks it into the shaped tc class, "block" drops it at all
        hours, and "alternate" blocks it on odd days of the month and throttles
        it on even ones.

        Day of month rather than a strict alternation from some epoch, because
        it can be read off a calendar. The price is that the 31st and the 1st
        are both odd, so seven times a year there are two block days in a row.

        The default is "throttle" so that a router which sets nothing behaves
        exactly as it did before this option existed.
      '';
    };
    # A second throttle tier, independent of `throttle` above, applied whenever
    # imoPolicy is throttling. Rate capped and lossy at every hour: unlike the
    # tunnel tier there is no added latency, because for imo the cap and the
    # loss are the whole mechanism.
    imoThrottle = {
      rate = lib.mkOption {
        type = lib.types.str;
        default = "384kbit";
        description = "Rate cap applied to imo addresses, each direction, at all hours.";
      };
      # Flat, where this was once a base value and a higher one during the
      # windows the household places calls in. Nothing was left using the
      # schedule once bongo moved to blocking outright and bingo went flat, and
      # a half-hourly timer maintaining a value nothing reads is machinery that
      # can only break. Git history has the windowed version.
      loss = lib.mkOption {
        type = lib.types.str;
        default = "3%";
        description = "Packet loss applied to imo addresses, at all hours.";
      };
    };
    # A pool of devices given a stricter egress policy than the rest of the
    # LAN, identified by MAC. See
    # docs/superpowers/specs/2026-08-13-low-trust-device-pool-design.md.
    #
    # MAC rather than IP because a device that sets its own address stays in
    # the pool. The known and unmitigated weakness is the other direction: a
    # device that randomises its MAC leaves the pool silently, and this network
    # has seen MAC rotation before.
    lowTrust = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enforce the low-trust device pool. Off means no sets, no chains, no service, and no tool.";
      };
      macFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = ''
          Path to the decrypted file listing pool MAC addresses, one per line,
          `#` comments allowed.

          A path rather than a list of strings on purpose: the list identifies
          people's devices, this repository is public, and anything given to a
          NixOS option ends up world-readable in the Nix store. Point this at a
          sops secret's `.path`.
        '';
      };

      cdnQuota = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Shape a pool device's traffic to CDN space once it exceeds a volume
            budget, instead of blocking it. Off means no sets, no chain and no
            generated file.

            For domain fronting, which neither of the other instruments reach:
            the edge address is shared with everything legitimate the house
            does, and the cover name is never resolved so no DNS rule sees it.
            Volume is what separates the two — see
            custom-cdn-quota-asns.txt for the measurements.
          '';
        };
        bytesPerSecond = lib.mkOption {
          type = lib.types.ints.positive;
          default = 5825;
          description = ''
            Sustained refill rate of the per-device token bucket, in BYTES per
            second. 5825 is 20.97 MB/hour.

            Bytes per second rather than the "20 mbytes/hour" nftables would
            accept in its grammar, because this kernel rejects that form:

              Error: Could not process rule: Value too large for defined data type

            Byte-unit rate limits overflow on /hour. /second and /minute load
            fine. Keeping the option in bytes/second makes the broken form
            impossible to write by accident.
          '';
        };
        burst = lib.mkOption {
          type = lib.types.str;
          default = "50 mbytes";
          description = ''
            Bucket capacity — the allowance a device gets at full link speed
            before shaping begins, refilled at bytesPerSecond.

            An nftables byte quantity, e.g. "50 mbytes". Values of 20, 50, 100
            and 500 mbytes were all accepted by this kernel and echoed back
            unchanged.

            This is the knob that decides the collateral. A pool device pulling
            a single update larger than this from a CDN will trip the quota and
            then crawl, which is the known and accepted cost of the feature.
          '';
        };
      };
    };

    # The access points, listed on the status page with one lamp each. See
    # web/aps.go for what the three states mean and how they are measured.
    #
    # These hang off a switch rather than off the router, so there is no link
    # state to read and no PHY to interrogate: the state is inferred from ICMP,
    # which is all a router can ask an unmanaged AP it has no credentials for.
    accessPoints = {
      file = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = ''
          Path to the decrypted file listing access points, one
          `name,address` or `name,address,username,password` per line, `#`
          comments allowed. Null disables the section: no list, no probe
          socket, no goroutine. A line with a login gains a reboot button on
          the status page; a line without one is a lamp only.

          Because a line may carry a password, point this at a sops secret kept
          readable by the router-ap group rather than world-readable — see
          web.nix, which puts router-web in that group. On a router whose list
          has no logins the mode does not matter, but the reboot feature needs
          it.

          A path rather than a list of strings for the same reason
          `lowTrust.macFile` is one: this repository is public and anything
          given to a NixOS option ends up world-readable in the Nix store.

          A malformed line disables the whole list rather than being skipped —
          an access point silently missing from the page reads as one that is
          fine, which is the failure the page exists to prevent.
        '';
      };

    };

    bandwidth = {
      upload = lib.mkOption {
        type = lib.types.str;
        default = "270Mbit";
        description = "Upload speed to WAN.";
      };
      download = lib.mkOption {
        type = lib.types.str;
        default = "900Mbit";
        description = "Download speed from WAN.";
      };
    };
    # Continuous measurement of what the uplink is actually delivering, as
    # opposed to how much of it is being used. node_exporter answers the
    # second question and cannot answer the first, which is the one that gets
    # asked when a call breaks up while the throughput graphs look idle.
    #
    # The prober lives in router-web (see web/uplink.go) and keeps its own
    # SQLite history on the router, because the retention this needs (a
    # quarter) is longer than Prometheus keeps and the history has to be
    # readable from the LAN during the outage that produced it. The same
    # figures are exported at /metrics for Grafana; the database is the long
    # memory, not a replacement for the dashboard.
    uplink = {
      enable = lib.mkEnableOption "uplink quality probing on the status page";
      anchors = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.strMatching "[a-zA-Z0-9_-]+";
                description = ''
                  Label for this anchor. Appears as a Prometheus label and as
                  the row heading on the page, so it wants to be short and
                  stable — renaming one starts a new series and orphans the
                  old history under the previous name.
                '';
              };
              address = lib.mkOption {
                type = lib.types.str;
                description = "IPv4 address to probe. An address, never a name: a name that later resolves elsewhere silently changes what is being measured.";
              };
              role = lib.mkOption {
                type = lib.types.enum [
                  "core"
                  "transit"
                ];
                description = ''
                  What this anchor is evidence about.

                  "core" is in-country and measures the ISP's own network. On
                  this ISP the public resolvers answer from anycast nodes
                  inside the country at around 5 ms, which makes them core
                  anchors whatever their operator's headquarters is.

                  "transit" is a unicast host abroad and is the only role that
                  sees international peering, which is the part that actually
                  degrades here. It has to be unicast: another anycast address
                  would be answered by a nearer node and quietly become a
                  second core anchor measuring the same 5 ms.
                '';
              };
              pairVoice = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Also probe this address a second time with DSCP EF, so the
                  packets land in CAKE's Voice tin instead of best effort.

                  Not a better measurement — a second one. Read alone the Voice
                  row is low by construction, because that tin is small and
                  protected and almost nothing else uses it. The reading is the
                  gap against its best-effort twin:

                  - both clean: the line is fine.
                  - best effort degraded, Voice flat: prioritisation is doing
                    its job, bulk traffic is contending, calls are unaffected.
                  - both degraded: the queue is upstream of this router, where
                    the shaper cannot reach it. That is the case worth taking
                    to the ISP, and nothing else here can distinguish it.

                  An upload differential only. The tin is chosen by the DSCP
                  written on egress; replies come back however the ISP sent
                  them, and this router bleaches WAN DSCP on arrival anyway.

                  Costs one extra probe per second and one extra row on the
                  page, so it is off unless a specific question needs it.
                '';
              };
            };
          }
        );
        default = [ ];
        example = lib.literalExpression ''
          [
            { name = "cloudflare"; address = "1.1.1.1"; role = "core"; }
            { name = "lighthouse"; address = "203.0.113.10"; role = "transit"; }
          ]
        '';
        description = ''
          Fixed targets probed once a second each.

          The PPP peer is always probed in addition to these and is not listed
          here: its address is discovered from the interface and rediscovered
          on every reconnect, since the access node is not obliged to hand back
          the same one. It is the liveness check and nothing more — its latency
          and jitter measure that node's control plane rather than the line,
          which is visible in the fact that it answers with an order of
          magnitude more jitter than targets reached *through* it.
        '';
      };
      retentionDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 90;
        description = ''
          How long per-minute history is kept. Roughly 4 KB per target per day,
          so the default costs a few tens of megabytes for a handful of
          anchors.

          Events — session drops, address changes, sustained degradation — are
          never expired regardless of this, because a flap from four months ago
          is exactly the kind of thing worth citing and the whole table is
          kilobytes.
        '';
      };
    };
    qos = {
      highPriorityPorts = lib.mkOption {
        type = with lib.types; listOf port;
        default = [ ];
        description = "TCP/UDP ports to mark as high-priority latency-sensitive traffic.";
      };
      highPriorityMark = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Conntrack mark used for high-priority traffic classification.";
      };
      highPriorityDscp = lib.mkOption {
        type = lib.types.str;
        default = "cs5";
        description = "DSCP class applied to high-priority traffic.";
      };
      prioritiseWebRTC = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Mark WebRTC conversations high-priority by matching the STUN magic
          cookie in the UDP payload. Catches video calls (Teams, Slack, Meet)
          regardless of which ports or relay addresses they negotiate.
        '';
      };
      lowPriorityPorts = lib.mkOption {
        type = with lib.types; listOf port;
        default = [ ];
        description = "TCP/UDP ports to mark as low-priority bulk traffic.";
      };
      lowPriorityMark = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Conntrack mark used for low-priority traffic classification.";
      };
      lowPriorityDscp = lib.mkOption {
        type = lib.types.str;
        default = "cs1";
        description = "DSCP class applied to low-priority traffic.";
      };
      lowTrustMark = lib.mkOption {
        type = lib.types.int;
        default = 9;
        description = ''
          Conntrack mark stamped on a low-trust device's conversations. A
          sentinel, not a priority class: no rule in qos-mark translates it into
          a DSCP codepoint, so a flow carrying it lands in CAKE's best-effort
          tin, and the single rule that matches it short-circuits the rest of
          the chain so nothing can promote the flow afterwards.

          Must differ from highPriorityMark and lowPriorityMark, or the
          translation rules would give pool devices the very class the pool
          exists to deny them, and must be non-zero — zero is what an
          unclassified conntrack entry already carries and could not be told
          apart from a pool one. Both are asserted at build time.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The low-trust sentinel only works by being a value nothing else in
    # qos-mark can produce or translate. A collision would not fail the ruleset
    # load — it would quietly hand pool devices the Voice tin, which is the one
    # outcome the pool exists to prevent, so it is caught at build time.
    assertions = [
      {
        assertion =
          cfg.qos.lowTrustMark != 0
          && cfg.qos.lowTrustMark != cfg.qos.highPriorityMark
          && cfg.qos.lowTrustMark != cfg.qos.lowPriorityMark;
        message = ''
          sifr.router.qos.lowTrustMark (${toString cfg.qos.lowTrustMark}) must be
          non-zero and must differ from highPriorityMark
          (${toString cfg.qos.highPriorityMark}) and lowPriorityMark
          (${toString cfg.qos.lowPriorityMark}).
        '';
      }

      # The quota chain is entered on the sentinel conntrack mark, and that mark
      # is only ever stamped inside the lowTrust.enable block below. With the
      # pool off, the chain loads cleanly, matches nothing and shapes nothing —
      # a silent fail-open, which is the one failure mode this whole feature is
      # written against. Caught here rather than discovered from a flat counter.
      {
        assertion = !cfg.lowTrust.cdnQuota.enable || cfg.lowTrust.enable;
        message = ''
          sifr.router.lowTrust.cdnQuota.enable requires
          sifr.router.lowTrust.enable. The quota chain is entered on the
          qos.lowTrustMark conntrack sentinel, which nothing stamps when the
          pool is off, so the rules would never match.
        '';
      }
    ];

    boot.kernelModules = [
      "sch_cake"
    ];
    boot.kernel.sysctl = {
      "net.core.default_qdisc" = lib.mkForce "cake";

      # Forwarding IPv4
      "net.ipv4.ip_forward" = 1;

      # Conntrack tracks every flow regardless; this only asks it to keep the
      # byte and packet totals it otherwise throws away. Both the
      # host-flow-textfile collector (host-metrics.nix) and the mesh-only
      # peers page (web.nix / web/peers.go) read conntrack's `bytes=` fields
      # and depend on this being set — without it every line is skipped and a
      # live device is indistinguishable from an idle one. Set here,
      # unconditionally on the router, rather than gated on the o11y client
      # like the collector is, since the peers page needs it regardless of
      # whether o11y is enabled.
      "net.netfilter.nf_conntrack_acct" = 1;

      # Stop rate-limiting ICMP destination-unreachable, which is the type
      # fragmentation-needed rides on and therefore all of IPv4 path MTU
      # discovery. The default mask is 6168 — bits 3, 4, 11 and 12 — and at the
      # default one-per-second interval a router behind a 1492-byte PPPoE
      # uplink can tell at most one flow per second, house-wide, that its
      # packet was too big. Every other oversized flow is simply dropped in
      # silence. 6160 is the same mask with bit 3 cleared, leaving source
      # quench, time-exceeded and parameter-problem limited as before.
      #
      # This is not unbounded: net.ipv4.icmp_msgs_per_sec (1000/s, burst 50)
      # is a separate global token bucket that still applies. The per-type
      # limiter is the one that was pathologically tight for this purpose.
      #
      # The IPv6 side already gets this right without help — the default
      # ratemask is 0-1,3-127, which omits type 2 (Packet Too Big).
      "net.ipv4.icmp_ratemask" = 6160;
    }
    // lib.optionalAttrs config.networking.enableIPv6 {
      # Forwarding IPv6
      "net.ipv6.conf.all.forwarding" = 1;

      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };

    environment.systemPackages = with pkgs; [
      conntrack-tools
      flent
      iftop
      bmon
    ];

    systemd.network = {
      enable = true;
      networks = {
        "10-wan" = {
          matchConfig.Name = cfg.wan;
          linkConfig.RequiredForOnline = "no";
          networkConfig = {
            DHCP = "no";
            LinkLocalAddressing = "no";
          }
          // lib.optionalAttrs config.networking.enableIPv6 {
            IPv6AcceptRA = false;
          };
        };
        "20-lan0" = {
          matchConfig.Name = cfg.lan0;
          address = [ cfg.lanAddress ];
          linkConfig.RequiredForOnline = "routable";
          networkConfig = {
            DHCP = "no";
            ConfigureWithoutCarrier = true;
          }
          // lib.optionalAttrs config.networking.enableIPv6 {
            IPv6AcceptRA = false;
            DHCPPrefixDelegation = true;
            IPv6SendRA = true;
          };
        }
        // lib.optionalAttrs config.networking.enableIPv6 {
          dhcpPrefixDelegationConfig = {
            UplinkInterface = cfg.ppp;
            SubnetId = 0;
            Announce = true;
          };
          # Advertise the router as the IPv6 recursive DNS server (RDNSS) and
          # the local domain as a search list (DNSSL) so IPv6-only clients have
          # a resolver. The link-local address is used rather than the global
          # one because the delegated prefix changes (e.g. on the daily PPP
          # redial); the link-local address is stable, and blocky already
          # listens on it (it binds every address on port 53).
          #
          # There is deliberately no MTU option here, and it is not an
          # oversight. The uplink is 1492 and clients get 1500 off the LAN
          # Ethernet, so advertising it would save them a round of PMTUD — but
          # networkd cannot. systemd 260 has no `[IPv6SendRA] Mtu=`, and
          # setting `[Link] MTUBytes=` on this interface does not reach the RA
          # either: the only caller of sd_radv_set_mtu() is link_update_mtu()
          # in networkd-link.c, guarded by `if (link->radv)`, and
          # radv_configure() never sets it. The option therefore appears only
          # if the link MTU changes while radv is already up, which does not
          # happen at boot. Tried on 2026-08-21 and confirmed absent on the
          # wire, with clients still at ipv6 mtu 1500 after 800s.
          #
          # Living without it is fine. ICMPv6 Packet Too Big is not
          # rate-limited (the default ratemask 0-1,3-127 omits type 2), so
          # PMTUD works; clients were observed caching mtu 1492 correctly.
          # Advertising it properly means corerad or radvd on this link, which
          # also means rehoming the delegated prefix that
          # DHCPPrefixDelegation/Announce currently feeds to radv.
          ipv6SendRAConfig = {
            EmitDNS = true;
            DNS = [ "_link_local" ];
            EmitDomains = true;
            Domains = [ cfg.localDomain ];
          };
        };
        "30-ppp0" = {
          matchConfig.Name = cfg.ppp;
          linkConfig.RequiredForOnline = "no";
          networkConfig = {
            KeepConfiguration = "yes";
          }
          // lib.optionalAttrs config.networking.enableIPv6 {
            DHCP = "ipv6";
            IPv6AcceptRA = true;
            IPv6PrivacyExtensions = false;
          };
        }
        // lib.optionalAttrs config.networking.enableIPv6 {
          dhcpV6Config = {
            WithoutRA = "solicit";
            UseDNS = false;
          };
          ipv6AcceptRAConfig = {
            UseDNS = false;
            UseDomains = false;
          };
        };
      };
    };

    networking = {
      useDHCP = false;
      useNetworkd = true;
      nameservers = [ "127.0.0.1" ];
      nftables.enable = true;
      firewall = {
        enable = true;
        filterForward = true;

        interfaces.${cfg.lan0} = {
          allowedTCPPorts = [
            53 # DNS TCP
            22 # SSH from LAN
            80 # Router landing page
          ];
          allowedUDPPorts = [
            53 # DNS UDP
            67 # DHCPv4 server
            123 # NTP, served by chrony — see ntp.nix
          ];
        };

        extraForwardRules = ''
          iifname "${cfg.lan0}" oifname "${cfg.ppp}" accept comment "LAN -> WAN"
        '';
      };
      nat = {
        enable = true;
        externalInterface = cfg.ppp;
        internalInterfaces = [ cfg.lan0 ];
      };
      resolvconf.useLocalResolver = true;
      nftables.tables = {
        "router-filter" = {
          family = "inet";
          content = ''
            set wan_bogon4 {
              type ipv4_addr
              flags interval
              elements = {
                0.0.0.0/8,
                10.0.0.0/8,
                100.64.0.0/10,
                127.0.0.0/8,
                169.254.0.0/16,
                172.16.0.0/12,
                192.168.0.0/16,
                224.0.0.0/4,
                240.0.0.0/4
              }
            }

            # Allow link-local ISP sources on PPP WAN so DHCPv6-PD and RA work.
            set wan_bogon6 {
              type ipv6_addr
              flags interval
              elements = {
                ::/128,
                ::1/128,
                fc00::/7,
                ff00::/8
              }
            }

            ${lib.optionalString cfg.lowTrust.enable ''
              # Declared here as well as in router-blocklists, and populated by
              # the same service. nftables sets are scoped to their table with
              # no way to share one, and qos-mark needs the membership as much
              # as the drop chains do. Two declarations, one writer.
              set lowtrust_macs {
                type ether_addr
              }

              set lowtrust_macs_temp {
                type ether_addr
              }
            ''}

            chain early-input {
              type filter hook input priority -10; policy accept;

              iifname "${cfg.ppp}" ip saddr @wan_bogon4 drop comment "Drop bogon or spoofed IPv4 sources on WAN"
              iifname "${cfg.ppp}" ip6 saddr @wan_bogon6 drop comment "Drop bogon or spoofed IPv6 sources on WAN"
              iifname "${cfg.ppp}" ip protocol icmp icmp type echo-request drop comment "Drop WAN IPv4 ping to router"
              iifname "${cfg.ppp}" meta l4proto ipv6-icmp icmpv6 type echo-request drop comment "Drop WAN IPv6 ping to router"
            }

            # Clamped in BOTH directions, which the obvious one-line version is
            # not. `oifname ppp0 ... size set rt mtu` only rewrites the SYN
            # leaving the LAN, and an MSS in a SYN says what the *sender* is
            # willing to receive — so that rule alone tells the far end to send
            # us small segments and never tells the LAN client anything. The
            # client keeps the MSS from the unclamped SYN-ACK (1460), emits
            # 1500-byte frames, and every one of them is too big for ppp0.
            #
            # Seen in 10.20.0.197-20260821-2305.pcap: server segments capped at
            # 1440 payload (clamped) while the phone's ran 1448 (not), each of
            # those answered by an ICMP frag-needed. It recovers by retransmit,
            # so it reads as "slow" rather than "broken" until ICMP is lost —
            # and the icmp_ratemask default handled above is exactly that loss.
            #
            # The return direction needs a literal size, not `rt mtu`: on a
            # WAN->LAN SYN-ACK the route lookup finds the LAN interface at 1500
            # and clamps to nothing. MSS excludes the TCP header but not TCP
            # options, hence mtu - 20 - 20 for v4 and mtu - 40 - 20 for v6.
            #
            # The `size > N` match in front of each `size set N` is load-bearing
            # and not redundant. A literal `size set` writes the value whether
            # or not it is an improvement, so a far end that legitimately asked
            # for a small MSS — anything already behind a tunnel — would have it
            # raised to ours and be blackholed by us. Clamping only ever lowers.
            chain mss-clamp {
              type filter hook forward priority mangle; policy accept;
              oifname "${cfg.ppp}" tcp flags syn tcp option maxseg size set rt mtu comment "Clamp MSS for PPPoE WAN (LAN to WAN)"
              iifname "${cfg.ppp}" meta nfproto ipv4 tcp flags syn tcp option maxseg size > ${toString (cfg.pppMtu - 40)} tcp option maxseg size set ${toString (cfg.pppMtu - 40)} comment "Clamp MSS for PPPoE WAN (WAN to LAN, IPv4)"
              iifname "${cfg.ppp}" meta nfproto ipv6 tcp flags syn tcp option maxseg size > ${toString (cfg.pppMtu - 60)} tcp option maxseg size set ${toString (cfg.pppMtu - 60)} comment "Clamp MSS for PPPoE WAN (WAN to LAN, IPv6)"
            }

            # Classification and DSCP application are deliberately separated
            # below. Every rule in the first half only ever writes a ct mark;
            # the DSCP rules at the bottom translate the final mark into a
            # diffserv codepoint for CAKE. Keeping them apart is what lets the
            # classifiers be independently optional — folding the dscp rules
            # back into the highPriorityPorts block would mean a host that
            # enables prioritiseWebRTC without setting any high-priority ports
            # marks its conntrack entries and then never acts on them.
            #
            # ct mark rather than meta mark throughout, and not just as a
            # matter of taste: the mark lives on the conntrack entry, so it is
            # set once by whichever packet matches and then applies to every
            # later packet of the same conversation in both directions. That
            # is load-bearing for the WebRTC rule below. It is also a
            # different namespace from the meta marks that forward_throttle in
            # ip-blocklist.nix writes (0x2/0x3 for the tc fw filters), so the
            # two schemes cannot collide despite the overlapping numbers.
            #
            # The ct mark space has three values, not two: highPriorityMark and
            # lowPriorityMark each translate into a codepoint at the bottom of
            # the chain, and lowTrustMark deliberately translates into none. It
            # is a sentinel that pulls a flow out of the chain entirely — see
            # the low-trust block below for why that needed to be a mark rather
            # than a match.
            chain qos-mark {
              type filter hook forward priority mangle; policy accept;

              # Bleach DSCP arriving from the WAN before anything below can act
              # on it. Without this the download shaper honours whatever
              # codepoint the remote sender chose: the diffserv4 classifier on
              # the lan0 egress qdisc reads the DSCP on the packet, and nothing
              # else in this chain overwrites a codepoint on a flow it has not
              # itself classified. A CDN marking bulk video AF41 would land in
              # the Video tin, and anything marking EF or CS5 would share the
              # Voice tin with real calls. Remote senders do not get to pick
              # which queue they sit in on this link.
              #
              # Safe to do wholesale only because every classifier below keys
              # off ct mark, which is set from the local port lists and the
              # STUN signature rather than from the incoming codepoint — so a
              # download that this router considers high-priority is re-marked
              # further down regardless of having just been bleached here.
              #
              # cs0 rather than a `dscp set 0` on the whole tos byte: ECN lives
              # in the low two bits of the same field and CAKE reads it, so
              # zeroing the byte would disable ECN signalling for every
              # forwarded flow.
              iifname "${cfg.ppp}" meta nfproto ipv4 counter ip dscp set cs0 comment "Bleach DSCP arriving from WAN (IPv4)"
              iifname "${cfg.ppp}" meta nfproto ipv6 counter ip6 dscp set cs0 comment "Bleach DSCP arriving from WAN (IPv6)"

              # LOW-TRUST POOL. A pool device's conversations never reach CAKE's
              # Voice tin — not the tunnel's, and not its calls either. They are
              # never dropped or throttled, only never prioritised, which is the
              # accepted trade.
              #
              # The mechanism is a sentinel ct mark (qos.lowTrustMark) that no
              # rule below translates into a codepoint, plus one `return` that
              # takes a flow carrying it straight out of the chain. So a pool
              # flow leaves qos-mark with cs0 and lands in best-effort.
              #
              # WHY A SENTINEL, and not the `ct mark set 0` placed after the
              # classifiers that this was until 2026-08-13. `ether saddr` can
              # only match upload: a download's source MAC is the ISP's, and
              # there is no download-direction equivalent (matching the LAN
              # address instead would miss a device that changes it). The ct
              # mark crossing both directions was assumed to cover that. It does
              # not, because the rules being neutralised are themselves
              # direction-agnostic and run on every packet. A STUN Binding
              # Success Response arriving from the WAN carries the same magic
              # cookie as the request, so the STUN rule re-marked the flow high
              # on the way in; the ether-saddr rules could not match that packet
              # to undo it; and the translation rules then wrote EF onto it.
              # Download flapped between best-effort and Voice for the life of
              # the call. Any highPriorityPorts match on `sport` had the same
              # hole. Pre-empting the classifiers and refusing to re-enter them
              # is what closes it: the download packet never reaches a rule that
              # could promote it.
              #
              # ONE `return` RATHER THAN NINE GUARDS. The alternative was
              # `ct mark != sentinel` bolted onto each of the four
              # highPriorityPorts rules, the STUN rule and the four
              # lowPriorityPorts rules. A guard that must be repeated is a guard
              # someone forgets on the tenth rule; expressed once, the sentinel
              # structurally cannot reach the translation rules at the bottom of
              # this chain, whatever is added between here and there.
              #
              # `return` from a base chain applies the chain policy (accept) and
              # evaluation carries on at the next hook, so nothing outside
              # qos-mark is skipped — only the rules that could promote this
              # flow. Counted like everything else here: a zero counter on it
              # means the pool is empty or the sets failed to load, which is the
              # silent fail-open this feature keeps guarding against.
              #
              # One accepted consequence: a conversation still open when a
              # device leaves the pool keeps the sentinel until its conntrack
              # entry expires. New flows are unaffected, and ICE renegotiation
              # produces new flows.
              ${lib.optionalString cfg.lowTrust.enable ''
                ether saddr @lowtrust_macs counter ct mark set ${toString cfg.qos.lowTrustMark} comment "Low-trust device: no priority"
                ether saddr @lowtrust_macs_temp counter ct mark set ${toString cfg.qos.lowTrustMark} comment "Low-trust device: no priority (temp)"

                # Closes a hole that exists today for every device and is only
                # closed here for pool ones: the bleach rules above strip DSCP
                # arriving from the WAN, but a LAN device's own upload codepoint
                # is untouched, so a device can mark its own packets EF and
                # reach the Voice tin on the uplink regardless of its ct mark.
                # Ahead of the return, which would otherwise skip them. The
                # `meta nfproto` matches are for counter placement, for the
                # reason spelled out on the translation rules below.
                ether saddr @lowtrust_macs meta nfproto ipv4 counter ip dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv4)"
                ether saddr @lowtrust_macs meta nfproto ipv6 counter ip6 dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv6)"
                ether saddr @lowtrust_macs_temp meta nfproto ipv4 counter ip dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv4, temp)"
                ether saddr @lowtrust_macs_temp meta nfproto ipv6 counter ip6 dscp set cs0 comment "Low-trust device: bleach self-marked DSCP (IPv6, temp)"

                # Matches in both directions, unlike everything above it: this
                # is the rule that catches the download half, which carries the
                # sentinel on its conntrack entry but no LAN MAC to match on.
                ct mark ${toString cfg.qos.lowTrustMark} counter return comment "Low-trust device: leave QoS classification"
              ''}

              ${lib.optionalString (cfg.qos.highPriorityPorts != [ ]) ''
                tcp sport { ${formatPorts cfg.qos.highPriorityPorts} } counter ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority TCP source ports"
                tcp dport { ${formatPorts cfg.qos.highPriorityPorts} } counter ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority TCP destination ports"
                udp sport { ${formatPorts cfg.qos.highPriorityPorts} } counter ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority UDP source ports"
                udp dport { ${formatPorts cfg.qos.highPriorityPorts} } counter ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority UDP destination ports"
              ''}

              # Catches calls (Teams, Slack, Meet, and anything else built on
              # WebRTC) without needing to know their ports or addresses,
              # neither of which are stable.
              #
              # @th is the transport header, so the offset counts from the
              # start of the UDP header: 64 bits of header then the STUN magic
              # cookie at payload bytes 4-7, hence bit 96 for 32 bits. The
              # cookie is a fixed constant every STUN message carries, which
              # makes this a payload signature rather than a port guess.
              #
              # Only the ICE negotiation carries the cookie — the SRTP media
              # that follows on the same 5-tuple does not, and would be
              # unmatchable on its own. Setting a ct mark rather than a packet
              # mark is what bridges that: the binding request marks the
              # conntrack entry and every media packet afterwards inherits it.
              # ICE consent freshness re-sends a binding request every few
              # seconds, so the mark is refreshed for the life of the call.
              #
              # Placed after the high-priority port rules and before the
              # low-priority ones so that the existing precedence is
              # unchanged: an explicit low-priority port still overrides, and
              # a bulk protocol that happens to speak STUN stays demoted.
              #
              # Counted because a payload match at a fixed offset is the kind
              # of rule that silently stops matching — a zero counter here
              # means the signature is wrong, not that nobody made a call.
              ${lib.optionalString cfg.qos.prioritiseWebRTC ''
                meta l4proto udp @th,96,32 0x2112a442 counter ct mark set ${toString cfg.qos.highPriorityMark} comment "Prioritise STUN/ICE (WebRTC) conversations"
              ''}

              ${lib.optionalString (cfg.qos.lowPriorityPorts != [ ]) ''
                tcp sport { ${formatPorts cfg.qos.lowPriorityPorts} } counter ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority TCP source ports"
                tcp dport { ${formatPorts cfg.qos.lowPriorityPorts} } counter ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority TCP destination ports"
                udp sport { ${formatPorts cfg.qos.lowPriorityPorts} } counter ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority UDP source ports"
                udp dport { ${formatPorts cfg.qos.lowPriorityPorts} } counter ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority UDP destination ports"
              ''}

              # Translate the settled ct mark into DSCP for CAKE's diffserv4
              # classifier. Unconditional: the rules are inert when nothing
              # upstream has set a mark.
              #
              # The `meta nfproto` matches are redundant as matches — nft
              # derives the same dependency from the `ip`/`ip6` expression on
              # its own — but not as placement. The implicit version is
              # inserted where the family expression appears, which is after
              # the counter, so without these the v4 and v6 counters would each
              # tally both families and every number here would read double.
              # Same reason for the pair on the bleach rules above.
              ct mark ${toString cfg.qos.highPriorityMark} meta nfproto ipv4 counter ip dscp set ${cfg.qos.highPriorityDscp} comment "Prioritise marked IPv4 traffic"
              ct mark ${toString cfg.qos.highPriorityMark} meta nfproto ipv6 counter ip6 dscp set ${cfg.qos.highPriorityDscp} comment "Prioritise marked IPv6 traffic"
              ct mark ${toString cfg.qos.lowPriorityMark} meta nfproto ipv4 counter ip dscp set ${cfg.qos.lowPriorityDscp} comment "Deprioritise marked IPv4 traffic"
              ct mark ${toString cfg.qos.lowPriorityMark} meta nfproto ipv6 counter ip6 dscp set ${cfg.qos.lowPriorityDscp} comment "Deprioritise marked IPv6 traffic"
            }

            chain early-forward {
              type filter hook forward priority -10; policy accept;

              iifname "${cfg.ppp}" ip saddr @wan_bogon4 drop comment "Drop bogon or spoofed IPv4 sources on WAN"
              iifname "${cfg.ppp}" ip6 saddr @wan_bogon6 drop comment "Drop bogon or spoofed IPv6 sources on WAN"
              oifname "${cfg.ppp}" tcp dport { 23, 25, 139, 445 } drop comment "Drop forwarded insecure TCP services to WAN"
              oifname "${cfg.ppp}" udp dport { 69, 137, 138 } drop comment "Drop forwarded insecure UDP services to WAN"

              # Keep LAN clients on the router's resolver while allowing the router itself upstream access.
              #
              # Logged and counted the same way as the blocklist chains in
              # ip-blocklist.nix, under the nft-block-dns prefix. These rules
              # predate that logging and were silent, which meant a client
              # quietly retrying DNS or DoT past the resolver looked identical
              # to a client that had given up — the one case where you most
              # want to know which. Grafana needs nothing extra: nft log goes
              # to the kernel ring buffer, journald picks it up, alloy ships
              # the journal.
              #
              # Sampled, and the limit sits on its own rule rather than on the
              # verdict — sharing them would let packets over the rate escape
              # the drop as well as the log. Counters on the verdicts carry the
              # exact volume.
              # 8853 alongside 853: it is the conventional alternate port for
              # DNS-over-QUIC, which dns4all and a few other resolvers publish
              # on the same certificate as their DoT service. Same category as
              # 853 and nothing on this LAN speaks it for anything else, so it
              # belongs with the DNS rules rather than in the port blocklist —
              # drops then land under nft-block-dns, where a client retrying
              # encrypted DNS reads as one story in LogQL.
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" meta l4proto { tcp, udp } th dport { 53, 853, 8853 } limit rate 60/minute burst 20 packets log prefix "nft-block-dns " comment "sample DNS/DoT bypass drops"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 53 counter drop comment "Block LAN DNS bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport 53 counter drop comment "Block LAN DNS bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport { 853, 8853 } counter drop comment "Block LAN DoT/DoQ bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport { 853, 8853 } counter drop comment "Block LAN DoT/DoQ bypass to WAN"
            }
          '';
        };

        "router-nat" = {
          family = "ip";
          content = ''
            chain prerouting {
              type nat hook prerouting priority dstnat; policy accept;

              # Force classic DNS to local resolver on the router
              #iifname "${cfg.lan0}" udp dport 53 redirect to :53 comment "force DNS/UDP to local"
              #iifname "${cfg.lan0}" tcp dport 53 redirect to :53 comment "force DNS/TCP to local"
            }
          '';
        };
      };
    };

  };
}
