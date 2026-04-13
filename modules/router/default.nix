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
    ./pppd.nix
    ./client-mode.nix
    ./ip-blocklist.nix
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
      default = "192.168.1.1/24";
      description = "The LAN address configured on the router interface.";
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
    pppdConfig = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the ISP provided credentials for PPPoE authentication.";
    };
    ifb = lib.mkOption {
      type = lib.types.str;
      default = "ifb0";
      description = "Virtual interface for traffic shaping.";
    };
    dhcp = {
      rangeStart = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.100";
        description = "Start of the DHCP lease range.";
      };
      rangeEnd = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.200";
        description = "End of the DHCP lease range.";
      };
      leaseTime = lib.mkOption {
        type = lib.types.str;
        default = "12h";
        description = "Default DHCP lease time.";
      };
      routerAddress = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.1";
        description = "Router address advertised over DHCP.";
      };
      dnsServer = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.1";
        description = "DNS server advertised over DHCP.";
      };
      leasesFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/misc/dnsmasq.leases";
        description = "Path to the dnsmasq DHCP leases file.";
      };
      hostsFile = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Optional path to a dnsmasq static DHCP hosts file.";
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
        description = "Upload speed from WAN.";
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
      "ifb"
      "sch_cake"
    ];
    boot.kernel.sysctl = {
      "net.core.default_qdisc" = lib.mkForce "cake";

      # Forwarding IPv4/6
      "net.ipv4.ip_forward" = 1;
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
            IPv6AcceptRA = false;
          };
        };
        "20-lan0" = {
          matchConfig.Name = cfg.lan0;
          address = [ cfg.lanAddress ];
          linkConfig.RequiredForOnline = "routable";
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            ConfigureWithoutCarrier = true;
            DHCPPrefixDelegation = true;
            IPv6SendRA = true;
          };
          dhcpPrefixDelegationConfig = {
            UplinkInterface = cfg.ppp;
            SubnetId = 0;
            Announce = true;
          };
        };
        "30-ppp0" = {
          matchConfig.Name = cfg.ppp;
          linkConfig.RequiredForOnline = "no";
          networkConfig = {
            DHCP = "ipv6";
            IPv6AcceptRA = true;
            KeepConfiguration = "yes";
            IPv6PrivacyExtensions = false;
          };
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

            chain qos-mark {
              type filter hook forward priority mangle; policy accept;

              ${lib.optionalString (cfg.qos.highPriorityPorts != [ ]) ''
                tcp sport { ${formatPorts cfg.qos.highPriorityPorts} } ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority TCP source ports"
                tcp dport { ${formatPorts cfg.qos.highPriorityPorts} } ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority TCP destination ports"
                udp sport { ${formatPorts cfg.qos.highPriorityPorts} } ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority UDP source ports"
                udp dport { ${formatPorts cfg.qos.highPriorityPorts} } ct mark set ${toString cfg.qos.highPriorityMark} comment "Mark high-priority UDP destination ports"
                ct mark ${toString cfg.qos.highPriorityMark} ip dscp set ${cfg.qos.highPriorityDscp} comment "Prioritise marked IPv4 traffic"
                ct mark ${toString cfg.qos.highPriorityMark} ip6 dscp set ${cfg.qos.highPriorityDscp} comment "Prioritise marked IPv6 traffic"
              ''}

              ${lib.optionalString (cfg.qos.lowPriorityPorts != [ ]) ''
                tcp sport { ${formatPorts cfg.qos.lowPriorityPorts} } ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority TCP source ports"
                tcp dport { ${formatPorts cfg.qos.lowPriorityPorts} } ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority TCP destination ports"
                udp sport { ${formatPorts cfg.qos.lowPriorityPorts} } ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority UDP source ports"
                udp dport { ${formatPorts cfg.qos.lowPriorityPorts} } ct mark set ${toString cfg.qos.lowPriorityMark} comment "Mark low-priority UDP destination ports"
                ct mark ${toString cfg.qos.lowPriorityMark} ip dscp set ${cfg.qos.lowPriorityDscp} comment "Deprioritise marked IPv4 traffic"
                ct mark ${toString cfg.qos.lowPriorityMark} ip6 dscp set ${cfg.qos.lowPriorityDscp} comment "Deprioritise marked IPv6 traffic"
              ''}
            }

            chain early-forward {
              type filter hook forward priority -10; policy accept;

              iifname "${cfg.ppp}" ip saddr @wan_bogon4 drop comment "Drop bogon or spoofed IPv4 sources on WAN"
              iifname "${cfg.ppp}" ip6 saddr @wan_bogon6 drop comment "Drop bogon or spoofed IPv6 sources on WAN"
              oifname "${cfg.ppp}" tcp dport { 23, 25, 139, 445 } drop comment "Drop forwarded insecure TCP services to WAN"
              oifname "${cfg.ppp}" udp dport { 69, 137, 138 } drop comment "Drop forwarded insecure UDP services to WAN"

              # Keep LAN clients on the router's resolver while allowing the router itself upstream access.
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 53 drop comment "Block LAN DNS bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport 53 drop comment "Block LAN DNS bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" udp dport 853 drop comment "Block LAN DoT bypass to WAN"
              iifname "${cfg.lan0}" oifname "${cfg.ppp}" tcp dport 853 drop comment "Block LAN DoT bypass to WAN"
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
