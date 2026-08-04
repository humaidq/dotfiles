{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
  blockyCommon = import ./blocky-common.nix;
  customDNSMappings = blockyCommon.customDNS.mapping // cfg.customDNSMappings;

  # Reverse zone for the LAN: one octet of the router address per full byte of
  # the prefix on sifr.router.lanAddress, reversed. Derived rather than fixed
  # at two octets because the routers do not share a prefix length — a /16 LAN
  # gives 20.10.in-addr.arpa, a /24 gives 50.168.192.in-addr.arpa. Claiming a
  # shorter zone than the router owns would make dnsmasq authoritative (and
  # so NXDOMAIN) for reverse lookups of addresses on other networks.
  lanPrefix = lib.toInt (lib.elemAt (lib.splitString "/" cfg.lanAddress) 1);
  lanOctets = lib.splitString "." cfg.dhcp.routerAddress;
  reverseZone = lib.concatStringsSep "." (
    lib.reverseList (lib.take (lanPrefix / 8) lanOctets)
    ++ [
      "in-addr"
      "arpa"
    ]
  );

  # dnsmasq only serves DNS to blocky, on loopback.
  dnsmasqUpstream = "127.0.0.1:5353";

  # blocky's custom DNS resolver runs ahead of its conditional resolver and
  # matches subdomains, so any mapping at or above the local domain (e.g.
  # alq.ae for a v6.alq.ae LAN) would shadow every DHCP-derived hostname.
  # Those entries are moved to dnsmasq instead, which resolves specific
  # records (DHCP leases, host-record) before its own wildcards.
  shadowingMappings = lib.filterAttrs (
    name: _: lib.hasSuffix ".${name}" ".${cfg.localDomain}"
  ) customDNSMappings;

  # dnsmasq takes one address per directive, blocky takes a comma-separated
  # list, so expand them.
  shadowingAddresses = lib.concatLists (
    lib.mapAttrsToList (
      name: value: map (ip: "/${name}/${ip}") (lib.splitString "," value)
    ) shadowingMappings
  );
in

{
  config = lib.mkIf cfg.enable {

    # The reverse zone above is built from whole octets, so a prefix that ends
    # mid-octet has no classful zone to name. Nothing here needs one, so this
    # is an assertion rather than a CNAME delegation (RFC 2317).
    assertions = [
      {
        assertion = lanPrefix == 8 || lanPrefix == 16 || lanPrefix == 24;
        message = "sifr.router.lanAddress must use a /8, /16 or /24 prefix; got /${toString lanPrefix}";
      }
    ];

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

        # Wildcards taken over from blocky's custom DNS. DHCP leases and the
        # host-record above are more specific, so they still win.
        address = shadowingAddresses;

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
      settings =
        lib.recursiveUpdate blockyCommon {
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
          }
          // lib.mapAttrs (_: _: dnsmasqUpstream) shadowingMappings;

          # The doh denylist also catches the canary domain, and blocking runs
          # before the conditional resolver, so blocky would answer it with
          # 0.0.0.0. Clients only disable DoH on NXDOMAIN, which is what dnsmasq
          # returns, so let the query through to it.
          blocking.allowlists.general = blockyCommon.blocking.allowlists.general ++ [
            ''
              use-application-dns.net
            ''
          ];

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
        }
        // {
          # Set outside the recursiveUpdate, which would merge the removed
          # entries straight back in.
          customDNS = blockyCommon.customDNS // {
            mapping = lib.removeAttrs customDNSMappings (lib.attrNames shadowingMappings);
          };
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
