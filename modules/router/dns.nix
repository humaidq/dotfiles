{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
  blockyCommon = import ./blocky-common.nix;

  # The LAN is a /16 (see the sifr.router.lanAddress default), so the reverse
  # zone is the first two octets of the router address, reversed.
  lanOctets = lib.splitString "." cfg.dhcp.routerAddress;
  reverseZone = "${lib.elemAt lanOctets 1}.${lib.elemAt lanOctets 0}.in-addr.arpa";

  # dnsmasq only serves DNS to blocky, on loopback.
  dnsmasqUpstream = "127.0.0.1:5353";
in

{
  config = lib.mkIf cfg.enable {

    # dnsmasq is the DHCP server and the authoritative resolver for the zones
    # derived from DHCP (hostnames and their PTRs). It is deliberately *not* on
    # port 53: blocky sits in front so that it sees the real client addresses
    # rather than 127.0.0.1, which is what makes per-client blocking and
    # per-device metrics possible.
    services.dnsmasq = {
      enable = true;
      # dnsmasq is no longer the system resolver, so it should not add itself to
      # resolv.conf or subscribe to resolvconf for upstreams. The router module
      # already points the host at 127.0.0.1, which is now blocky.
      resolveLocalQueries = false;
      settings = {
        port = 5353;

        dhcp-range = [ "${cfg.dhcp.rangeStart},${cfg.dhcp.rangeEnd},${cfg.dhcp.leaseTime}" ];
        dhcp-leasefile = cfg.dhcp.leasesFile;
        interface = [
          cfg.lan0
          "sifr0"
        ];
        domain = cfg.localDomain;
        local = [
          "/${cfg.localDomain}/"
          # Reverse zone for the LAN, so client IPs resolve back to their DHCP
          # hostnames. blocky uses this for its client lookups.
          "/${reverseZone}/"
          # Answer the DoH canary domain authoritatively (NXDOMAIN) so Firefox
          # and other canary-respecting clients disable DNS-over-HTTPS and stay
          # on the router's resolver. blocky cannot do this itself, as its
          # blockType is zeroIp.
          "/use-application-dns.net/"
        ];
        expand-hosts = true;
        host-record = [ "${cfg.localDomain},${cfg.dhcp.routerAddress}" ];

        # No upstreams: blocky only ever asks about the local zones above, and
        # forwarding back to blocky would be a resolution loop.
        no-resolv = true;

        no-hosts = true;

        dhcp-option = [
          "option:router,${cfg.dhcp.routerAddress}"
          "option:dns-server,${cfg.dhcp.dnsServer}"
        ];
      }
      // lib.optionalAttrs (cfg.dhcp.hostsFile != null) {
        dhcp-hostsfile = cfg.dhcp.hostsFile;
      };
    };

    services.resolved.enable = false;

    services.blocky = {
      enable = true;
      settings = lib.recursiveUpdate blockyCommon {
        ports = {
          dns = 53;
          http = 3333;
          https = 4333;
          tls = 853;
        };

        # dnsmasq owns the DHCP-derived zones; hand those queries to it instead
        # of upstream. fallbackUpstream stays at its default (false) so local
        # names never leak out.
        conditional.mapping = {
          "${cfg.localDomain}" = dnsmasqUpstream;
          "${reverseZone}" = dnsmasqUpstream;
          "use-application-dns.net" = dnsmasqUpstream;
        };

        # Resolve client addresses to device names via dnsmasq's DHCP lease
        # PTRs, so clientGroupsBlock and the Prometheus metrics are per-device.
        clientLookup = {
          upstream = dnsmasqUpstream;
          singleNameOrder = [
            1
            2
          ];
        };

        # blocky's cache sits in front of its conditional resolver, so the
        # shared 6h minTime would pin DHCP hostname to address mappings for 6h
        # after a lease changes. Honour the real TTLs here instead.
        caching.minTime = "0";
      };
    }; # end blocky

    # Guarded on services.blocky.enable so the client specialisation, which
    # turns blocky off, does not end up with a stray unit.
    systemd.services.blocky = lib.mkIf config.services.blocky.enable {
      after = [ "dnsmasq.service" ];
      wants = [ "dnsmasq.service" ];
    };

  };
}
