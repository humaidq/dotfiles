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
    ./host-metrics.nix
    ./pppd.nix
    ./client-mode.nix
    ./ip-blocklist.nix
    ./suricata.nix
    ./tools.nix
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
    # These are deliberately bad rather than merely slow: the aim is a tunnel
    # that stays connected and is useless, because a client that fails cleanly
    # just reconnects somewhere else.
    throttle = {
      rate = lib.mkOption {
        type = lib.types.str;
        default = "100kbit";
        description = "Rate cap applied to throttled addresses, each direction.";
      };
      delay = lib.mkOption {
        type = lib.types.str;
        default = "400ms";
        description = "Latency added to throttled addresses.";
      };
      jitter = lib.mkOption {
        type = lib.types.str;
        default = "100ms";
        description = "Jitter around the added latency. Reorders packets, which hurts a tunnel more than the rate cap does.";
      };
      loss = lib.mkOption {
        type = lib.types.str;
        default = "3%";
        description = "Random packet loss applied to throttled addresses.";
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
    };
  };

  config = lib.mkIf cfg.enable {
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
            123 # NTP
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

            chain mss-clamp {
              type filter hook forward priority mangle; policy accept;
              oifname "${cfg.ppp}" tcp flags syn tcp option maxseg size set rt mtu comment "Clamp MSS for PPPoE WAN"
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
