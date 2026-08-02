{
  lib,
  pkgs,
  ...
}:
let
  routerAddress = "10.20.0.1";
  routerUplinkAddress = "192.0.2.1";
  wanServerAddress = "192.0.2.2";
  localDomain = "test.home.arpa";

  testInterface = name: vlan: {
    inherit name vlan;
    assignIP = false;
  };
in
{
  name = "router-core";

  defaults = {
    networking = {
      enableIPv6 = false;
      useDHCP = false;
    };

    environment.systemPackages = with pkgs; [
      curl
      dnsutils
      iproute2
      iputils
    ];
  };

  nodes = {
    router = {
      imports = [ ../../modules/router ];

      virtualisation = {
        interfaces = {
          lan = testInterface "eth1" 1;
          uplink = testInterface "eth2" 2;
          wan = testInterface "eth3" 3;
        };
        memorySize = 1024;
      };

      sifr.router = {
        enable = true;
        wan = "eth3";
        lan0 = "eth1";
        ppp = "eth2";
        inherit localDomain;
        pppdConfig = pkgs.writeText "pppd-test-config" ''
          user test
          password test
        '';
        dhcp = {
          rangeStart = "10.20.0.100";
          rangeEnd = "10.20.0.110";
        };
      };

      # The core test exercises everything after the PPP link is established.
      # A static Ethernet interface stands in for that link; PPPoE and CAKE get
      # their own focused scenario later.
      services.pppd.enable = lib.mkForce false;
      systemd.services."pppd-etisalat".enable = false;
      systemd.timers."pppd-uplink-redial".enable = false;

      # Keep Blocky deterministic and offline. Local and DHCP-derived names are
      # still resolved through the module's real dnsmasq integration.
      services.blocky.settings = {
        upstreams.groups.default = lib.mkForce [ wanServerAddress ];
        bootstrapDns = lib.mkForce [ ];
        blocking = {
          denylists = lib.mkForce {
            test = [ ./fixtures/blocky-denylist.txt ];
          };
          allowlists = lib.mkForce { };
          clientGroupsBlock = lib.mkForce {
            default = [ "test" ];
          };
        };
      };

      systemd.network = {
        netdevs."10-sifr0".netdevConfig = {
          Name = "sifr0";
          Kind = "dummy";
        };
        networks = {
          "20-sifr0" = {
            matchConfig.Name = "sifr0";
            address = [ "10.10.0.1/24" ];
            networkConfig.ConfigureWithoutCarrier = true;
          };
          "30-ppp0".address = [ "${routerUplinkAddress}/24" ];
        };
      };
    };

    client = {
      networking = {
        hostName = "lan-client";
        useNetworkd = true;
      };

      services.resolved.enable = true;

      virtualisation.interfaces.lan = testInterface "eth1" 1;

      systemd.network = {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "eth1";
          networkConfig = {
            DHCP = "ipv4";
            IPv6AcceptRA = false;
          };
          dhcpV4Config = {
            SendHostname = true;
            UseDNS = true;
            UseRoutes = true;
          };
        };
      };
    };

    wan = {
      networking = {
        defaultGateway = {
          address = routerUplinkAddress;
          interface = "eth1";
        };
        firewall.enable = false;
        interfaces.eth1.ipv4.addresses = [
          {
            address = wanServerAddress;
            prefixLength = 24;
          }
        ];
        useNetworkd = true;
      };

      virtualisation.interfaces.uplink = testInterface "eth1" 2;

      services = {
        dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            bind-interfaces = true;
            host-record = [ "upstream.test,${wanServerAddress}" ];
            listen-address = [ wanServerAddress ];
            no-resolv = true;
          };
        };
        nginx = {
          enable = true;
          virtualHosts.wan = {
            default = true;
            root = pkgs.writeTextDir "index.html" "wan-server\n";
            listen =
              map
                (port: {
                  addr = "0.0.0.0";
                  inherit port;
                })
                [
                  23
                  80
                  853
                ];
          };
        };
      };
    };
  };

  testScript = ''
    router.start()
    wan.start()

    router.wait_for_unit("systemd-networkd.service")
    router.wait_for_unit("nftables.service")
    router.wait_for_unit("nft-blocklists-local.service")
    router.wait_for_unit("dnsmasq.service")
    router.wait_for_unit("blocky.service")
    router.wait_for_unit("router-web.service")
    wan.wait_for_unit("dnsmasq.service")
    wan.wait_for_unit("nginx.service")

    with subtest("router services and generated policy"):
        router.succeed("test $(sysctl -n net.ipv4.ip_forward) -eq 1")
        router.succeed("nft list table inet router-filter | grep -q 'Block LAN DNS bypass to WAN'")
        router.succeed("nft list table inet router-blocklists | grep -q 'block LAN->WAN tunnel ports'")
        router.succeed("ping -c 1 -W 2 ${wanServerAddress}")
        router.succeed("dig @${wanServerAddress} upstream.test +short | grep -qx ${wanServerAddress}")

    client.start()
    client.wait_for_unit("systemd-networkd.service")
    client.wait_until_succeeds("ip -4 -o address show dev eth1 scope global | grep -Eq 'inet 10\\.20\\.0\\.10[0-9]/16'")

    client_ip = client.succeed(
        "ip -4 -o address show dev eth1 scope global | awk '{print $4}' | cut -d/ -f1"
    ).strip()

    with subtest("DHCP configuration"):
        assert client_ip.startswith("10.20.0.10"), client_ip
        client.succeed("ip route show default | grep -q 'via ${routerAddress} dev eth1'")
        client.wait_until_succeeds("resolvectl dns eth1 | grep -q ${routerAddress}")
        router.wait_until_succeeds("grep -q 'lan-client' /var/lib/dnsmasq/dnsmasq.leases")

    with subtest("router DNS"):
        client.wait_until_succeeds("dig @${routerAddress} test.huma.id A +short | grep -qx 1.1.1.1")
        client.wait_until_succeeds(f"dig @${routerAddress} lan-client.${localDomain} A +short | grep -qx {client_ip}")
        client.wait_until_succeeds(f"dig @${routerAddress} -x {client_ip} +short | grep -qx 'lan-client.${localDomain}.'")
        client.succeed("dig @${routerAddress} blocked.test A +short | grep -qx 0.0.0.0")
        client.succeed("dig @${routerAddress} use-application-dns.net A +noall +comments | grep -q 'status: NXDOMAIN'")

    with subtest("router landing page"):
        client.wait_until_succeeds("curl -fsS http://${routerAddress}/ | grep -q 'Gateway Status'")
        client.succeed("curl -fsS http://${routerAddress}/ | grep -q '${localDomain}'")

    with subtest("forwarding and NAT"):
        client.succeed("curl -fsS http://${wanServerAddress}/ | grep -q wan-server")
        wan.wait_until_succeeds("grep -q '^${routerUplinkAddress} ' /var/log/nginx/access.log")

    with subtest("forwarding firewall"):
        client.fail("timeout 3 dig @${wanServerAddress} upstream.test +time=1 +tries=1")
        client.fail("timeout 3 dig @${wanServerAddress} upstream.test +tcp +time=1 +tries=1")
        client.fail("curl --connect-timeout 2 http://${wanServerAddress}:853/")
        client.fail("curl --connect-timeout 2 http://${wanServerAddress}:23/")
        wan.fail(f"ping -c 1 -W 2 {client_ip}")
        wan.fail("ping -c 1 -W 2 ${routerUplinkAddress}")
  '';
}
