{
  config,
  lib,
  ...
}:
let
  wan = "enp1s0"; # eth0
  lan0 = "enp2s0"; # main lan, eth1 # secondary lan, eth2 (unused)
  ppp = "ppp0";
in
{
  sops.secrets."etisalat/pppd-config" = {
    sopsFile = ../../secrets/bongo.yaml;
  };
  sops.secrets."dnsmasq/dhcp-hosts" = {
    sopsFile = ../../secrets/bongo.yaml;
    owner = "dnsmasq";
    group = "dnsmasq";
    mode = "0400";
  };
  boot.kernel.sysctl = {
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
        matchConfig.Name = wan;
        linkConfig.RequiredForOnline = "no";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
      };
      "20-lan0" = {
        matchConfig.Name = lan0;
        address = [ "192.168.1.1/24" ];
        linkConfig.RequiredForOnline = "routable";
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          ConfigureWithoutCarrier = true;

          # TODO After confirmation
          # DHCPPrefixDelegation = true;
          # IPv6SendRA = true;
        };
        # TODO after confirmation
        #dhcpPrefixDelegationConfig = {
        #  UplinkInterface = "ppp0";
        #  SubnetId = 0;
        #  Announce = true;
        #};
      };
      "30-ppp0" = {
        matchConfig.Name = ppp;
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
    nftables.enable = true;
    firewall = {
      enable = true;
      filterForward = true;

      interfaces.${lan0} = {
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
        iifname "${lan0}" oifname "${ppp}" accept comment "LAN -> WAN"
      '';
    };
    nat = {
      enable = true;
      externalInterface = ppp;
      internalInterfaces = [ lan0 ];
    };
    nftables.tables = {
      "router-filter" = {
        family = "inet";
        content = ''
          chain early-forward {
            type filter hook forward priority -10; policy accept;

            # Prevent easy DNS bypasses
            #iifname "${lan0}" tcp dport 853 drop comment "block DoT"
            #iifname "${lan0}" udp dport 853 drop comment "block DoT"
          }
        '';
      };

      "router-nat" = {
        family = "ip";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;

            # Force classic DNS to local resolver on the router
            #iifname "${lan0}" udp dport 53 redirect to :53 comment "force DNS/UDP to local"
            #iifname "${lan0}" tcp dport 53 redirect to :53 comment "force DNS/TCP to local"
          }
        '';
      };
    };
  };

  services.pppd = {
    enable = true;
    peers.etisalat = {
      autostart = true;
      config = ''
        plugin pppoe.so

        file ${config.sops.secrets."etisalat/pppd-config".path}

        ifname ppp0

        +ipv6
        defaultroute

        persist
        maxfail 0
        holdoff 5

        noauth
        noproxyarp

        lcp-echo-interval 10
        lcp-echo-failure 3

        mtu 1492
        mru 1492

        noresolvconf
      '';
    };
  };

  services.dnsmasq = {
    enable = true;
    settings = {
      dhcp-range = [ "192.168.1.100,192.168.1.200,12h" ];
      dhcp-hostsfile = config.sops.secrets."dnsmasq/dhcp-hosts".path;
      interface = lan0;

      server = [
        "8.8.8.8"
        "8.8.4.4"
      ];

      no-hosts = true;

      dhcp-option = [
        "option:router,192.168.1.1"
        "option:dns-server,192.168.1.1"
      ];
    };
  };

  services.resolved.enable = lib.mkForce false;

  specialisation.client.configuration = {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkForce 0;
      "net.ipv6.conf.all.forwarding" = lib.mkForce 0;
    };

    systemd.network.networks = lib.mkForce {
      "10-wan" = {
        matchConfig.Name = wan;
        linkConfig.RequiredForOnline = "routable";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
        };
      };
    };

    networking = {
      firewall = {
        filterForward = lib.mkForce false;
        interfaces = lib.mkForce {
          ${wan}.allowedTCPPorts = [ 22 ];
        };
        extraForwardRules = lib.mkForce "";
      };
      nat.enable = lib.mkForce false;
      nftables.tables = {
        router-filter = lib.mkForce {
          family = "inet";
          content = "";
        };
        router-nat = lib.mkForce {
          family = "ip";
          content = "";
        };
      };
    };

    services = {
      dnsmasq.enable = lib.mkForce false;
      pppd.enable = lib.mkForce false;
    };
  };

  # TODO Restart pppd if systemd-networkd restarts
  #systemd.services."pppd-uplink" = {
  #  partOf = [ "systemd-networkd.service" ];
  #};

  # TODO Enfore redial once a day
  #systemd.services."pppd-uplink-redial" = {
  #  requires = [ "pppd-uplink.service" ];
  #  serviceConfig = {
  #    Type = "simple";
  #    ExecStart = "${pkgs.systemd}/bin/systemctl kill -s HUP --kill-who=main pppd-uplink";
  #  };
  #};
  #systemd.timers."pppd-uplink-redial" = {
  #  wantedBy = [ "timers.target" ];

  #  timerConfig = {
  #    OnCalendar = "*-*-* 05:00:00";
  #  };
  #};
}
