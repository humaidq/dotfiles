{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
in
{
  imports = [
    ./dns.nix
    ./qos.nix
    ./pppd.nix
    ./client-mode.nix
    ./ip-blocklist.nix
    ./tools.nix
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
    ppp = lib.mkOption {
      type = lib.types.str;
      default = "ppp0";
      description = "The PPP interface.";
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
          address = [ "192.168.1.1/24" ];
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
            chain early-input {
              type filter hook input priority -10; policy accept;

              iifname "${cfg.ppp}" ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop comment "Drop RFC1918 spoofed IPv4 sources on WAN"
              iifname "${cfg.ppp}" ip protocol icmp icmp type echo-request drop comment "Drop WAN IPv4 ping to router"
              iifname "${cfg.ppp}" meta l4proto ipv6-icmp icmpv6 type echo-request drop comment "Drop WAN IPv6 ping to router"
            }

            chain mss-clamp {
              type filter hook forward priority mangle; policy accept;
              oifname "${cfg.ppp}" tcp flags syn tcp option maxseg size set rt mtu comment "Clamp MSS for PPPoE WAN"
            }

            chain early-forward {
              type filter hook forward priority -10; policy accept;

              iifname "${cfg.ppp}" ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop comment "Drop RFC1918 spoofed IPv4 sources on WAN"
              oifname "${cfg.ppp}" tcp dport { 23, 25, 139, 445 } drop comment "Drop forwarded insecure TCP services to WAN"
              oifname "${cfg.ppp}" udp dport { 69, 137, 138 } drop comment "Drop forwarded insecure UDP services to WAN"

              # Prevent easy DNS bypasses
              #iifname "${cfg.lan0}" tcp dport 853 drop comment "block DoT"
              #iifname "${cfg.lan0}" udp dport 853 drop comment "block DoT"
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
