{
  config,
  lib,
  pkgs,
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

  # Link-local addresses mapped to DHCP names, regenerated from the neighbour
  # table. See v6-names.py for why this exists and why it is link-local only.
  v6NamesFile = "/var/lib/dnsmasq-v6-names/hosts";

  # fe80::/16, which is where every IPv6 query on this network is sourced from:
  # the RA advertises the router's link-local as the resolver, and a packet to a
  # link-local destination must carry a link-local source. Routed to dnsmasq so
  # the PTRs above are the ones blocky gets; without this the lookup goes
  # upstream and comes back NXDOMAIN, which is what it did before.
  v6ReverseZone = "8.e.f.ip6.arpa";

  v6Names = pkgs.writers.writePython3Bin "v6-names" { } (builtins.readFile ./v6-names.py);

  # blocky's custom DNS resolver runs ahead of its conditional resolver and
  # matches subdomains, so any mapping at or above the local domain (e.g.
  # alq.ae for a v6.alq.ae LAN) would shadow every DHCP-derived hostname.
  # Those entries are moved to dnsmasq instead, which resolves specific
  # records (DHCP leases, host-record) before its own wildcards.
  shadowingMappings = lib.filterAttrs (
    name: _: lib.hasSuffix ".${name}" ".${cfg.localDomain}"
  ) customDNSMappings;

  # The mapping for the local domain itself is already served, exactly, by the
  # host-record below — and better, since host-record also generates the PTR
  # that address= does not. Emitting it here as well adds nothing except an
  # address= wildcard, which matches every subdomain: with the domain handed
  # out as the DHCP search suffix, that turns `ping abcd` into a lookup of
  # abcd.<domain> answered with the router's own address instead of NXDOMAIN.
  # Dropped so the zone, which is declared local below, answers unknown names
  # the way it should.
  #
  # Only when the two agree. A mapping pointing the local domain somewhere
  # other than the router is not redundant, so it keeps its wildcard and its
  # existing behaviour. A mapping *above* the local domain (alq.ae for a
  # v6.alq.ae LAN) is what the wildcard was written for and is untouched.
  redundantWithHostRecord = name: value: name == cfg.localDomain && value == cfg.dhcp.routerAddress;

  # dnsmasq takes one address per directive, blocky takes a comma-separated
  # list, so expand them.
  shadowingAddresses = lib.concatLists (
    lib.mapAttrsToList (name: value: map (ip: "/${name}/${ip}") (lib.splitString "," value)) (
      lib.filterAttrs (name: value: !redundantWithHostRecord name value) shadowingMappings
    )
  );
in

{
  options.sifr.router.queryLog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Have blocky log every query it resolves to its stdout, and so to the
        journal. Two things read it, and they are why the setting exists.

        The peers page names a peer that has no PTR. An in-ISP CDN cache —
        most of what AS5384 answers with on this network — publishes no
        reverse record and never will, and its AS is the ISP's, so the row can
        say "Emirates Telecommunications Group" without saying whether it is
        serving Instagram or YouTube. The name a device asked for immediately
        before connecting is the missing half, and this log is the only source
        that has it.

        The router dashboard's DNS panels are the other reader, by way of
        Alloy shipping the journal to Loki. All twenty-one of them select on
        the "query resolved" line this produces.

        WHY THE JOURNAL AND NOT A FILE, since it was a file between 2026-08-28
        and 2026-08-30 and the change back is deliberate. blocky has exactly
        one queryLog. Pointing it at a csv file to serve the peers page took
        the line out of the journal, and every DNS panel emptied out within one
        15m window; the file could not feed them back, because the field list
        that made a file on the router acceptable — question and answer only —
        is missing the client and the block reason those panels are built on.
        One log with two readers is the only arrangement that serves both.

        WHAT THAT COSTS, stated plainly rather than left implicit. The journal
        line carries client_ip and client_names, so the router's journal holds
        which device looked up what for as long as journald keeps it. That is
        a per-device browsing history and it is the thing this repository is
        otherwise careful not to produce. It is accepted here because the same
        data already reaches Loki on oreamnos for the dashboard's own device
        picker, so refusing it on the router bought privacy that was not
        actually being kept — while costing every DNS panel.

        The peers page reader is narrower than the log it reads: see
        modules/router/web/answerlog.go, which parses the question and the
        answer and never the client fields sitting next to them.
      '';
    };

    unit = lib.mkOption {
      type = lib.types.str;
      default = "blocky.service";
      readOnly = true;
      description = ''
        The unit whose journal carries the log. Read-only and stated once
        because blocky writes it and router-web reads it, from two different
        modules, and a name spelled out in both is a name that eventually
        differs in one.
      '';
    };
  };

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
        local = lib.unique (
          [
            "/${cfg.localDomain}/"
            # Reverse zone for link-local addresses, so an IPv6 client's PTR is
            # answered here and not forwarded to an upstream that has never heard
            # of it.
            "/${v6ReverseZone}/"
            # Reverse zone for the LAN, so client IPs resolve back to their DHCP
            # hostnames. blocky uses this for its client lookups.
            "/${reverseZone}/"
            # Answer the DoH canary domain authoritatively (NXDOMAIN) so Firefox
            # and other canary-respecting clients disable DNS-over-HTTPS and stay
            # on the router's resolver. blocky cannot do this itself, as its
            # blockType is zeroIp.
            "/use-application-dns.net/"
          ]
          # The shadowed zones too. address= below answers A for them, but it
          # only answers A: an AAAA, HTTPS or TXT query for the same name is not
          # matched, so dnsmasq treats it as forwardable and — with no-resolv and
          # no upstreams — returns REFUSED. Clients read that as a broken server
          # and retry, which is what grafana.alq.ae was doing on every AAAA and
          # HTTPS lookup. Declaring the zone local makes those NODATA instead.
          ++ map (name: "/${name}/") (lib.attrNames shadowingMappings)
        );
        expand-hosts = true;

        # The generated IPv6 names. dnsmasq re-reads this on SIGHUP, which is
        # what the generator sends when the file actually changes.
        addn-hosts = v6NamesFile;
        host-record = [ "${cfg.localDomain},${cfg.dhcp.routerAddress}" ];

        # Wildcards taken over from blocky's custom DNS. DHCP leases and the
        # host-record above are more specific, so they still win.
        address = shadowingAddresses;

        # No upstreams: blocky only ever asks about the local zones above, and
        # forwarding back to blocky would be a resolution loop.
        no-resolv = true;

        no-hosts = true;

        # option:ntp-server is option 42. The router itself, because ntp.nix
        # makes chrony serve the LAN: a client that takes this stops reaching
        # for pool.ntp.org over the PPPoE link, which is both a round trip
        # shorter and one fewer thing that breaks while the uplink is down.
        #
        # routerAddress rather than a separate option, unlike dns-server: the
        # server being advertised is this box, so a second address to point it
        # somewhere else would only ever disagree with the chrony `allow` that
        # makes it work.
        dhcp-option = [
          "option:router,${cfg.dhcp.routerAddress}"
          "option:dns-server,${cfg.dhcp.dnsServer}"
          "option:ntp-server,${cfg.dhcp.routerAddress}"
        ];
      }
      // lib.optionalAttrs (cfg.dhcp.hostsFile != null) {
        dhcp-hostsfile = cfg.dhcp.hostsFile;
      };
    };

    # The generated link-local -> DHCP name map, and what keeps it current.
    #
    # A timer rather than an event, because there is no event to hang it on: a
    # device configures its own IPv6 address and tells nothing, so the first
    # anyone here knows of it is a neighbour table entry appearing. A minute is
    # short enough that a device is named in the DNS log almost as soon as it
    # starts querying, and the work is two file reads and a join.
    systemd.tmpfiles.rules = [
      "d ${dirOf v6NamesFile} 0755 root root -"
      # Created empty so dnsmasq has something to read at first start. Without
      # it dnsmasq logs a warning about the missing addn-hosts file on every
      # boot before the timer has first fired.
      "f ${v6NamesFile} 0644 root root -"
    ];

    systemd.services.dnsmasq-v6-names = {
      description = "Map IPv6 link-local addresses to DHCP names for dnsmasq";
      after = [ "dnsmasq.service" ];
      wants = [ "dnsmasq.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      path = with pkgs; [
        iproute2
        coreutils
      ];

      # The generator exits 1 when the rendered file is byte-identical to what
      # is already there, which is the common case: link-local addresses are
      # stable per device, so this changes only when a device joins or leaves.
      # Signalling dnsmasq unconditionally would mean a reload every minute
      # forever, and dnsmasq re-reads its lease file on SIGHUP.
      script = ''
        set -uo pipefail
        ip -6 neigh show dev ${cfg.lan0} > /run/dnsmasq-v6-neigh
        if ${v6Names}/bin/v6-names /run/dnsmasq-v6-neigh \
            ${lib.escapeShellArg cfg.dhcp.leasesFile} \
            ${lib.escapeShellArg cfg.localDomain} \
            ${lib.escapeShellArg v6NamesFile}; then
          systemctl kill -s HUP dnsmasq.service || true
        fi
        rm -f /run/dnsmasq-v6-neigh
      '';
    };

    systemd.timers.dnsmasq-v6-names = {
      description = "Refresh the IPv6 name map for dnsmasq";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "1m";
        AccuracySec = "10s";
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
            "${v6ReverseZone}" = dnsmasqUpstream;
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

          # minTime was forced to 0 here and now lives in blocky-common.nix
          # instead, which is router-only since hisn's resolver was removed.
          # See the note there: the DHCP-lease reason that put it here is
          # unchanged, and CDN steering is a second reason not to raise it.
        }
        // lib.optionalAttrs cfg.queryLog.enable {
          # The "query resolved" line, on stdout and so in the journal. Both
          # readers are described on sifr.router.queryLog.enable above; the
          # short version is that the peers page needs the answer and the
          # dashboard needs the client and the block reason, and blocky has
          # one query log to give.
          #
          # console is blocky's default type and this is really a statement
          # that it must stay the default. Naming it is the point: the obvious
          # way to serve the peers page is to point target at a file, and doing
          # that silently empties twenty-one dashboard panels because it moves
          # the line rather than copying it.
          #
          # No fields list, also deliberately. Restricting it to question and
          # responseAnswer is what a file on the router would need to be
          # acceptable, and it is exactly what starves the panels: they are
          # built on client_ip and response_reason, which a restricted list
          # blanks to 0.0.0.0 and drops entirely.
          queryLog.type = "console";
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

    # NOTHING GRANTS ACCESS TO THE QUERY LOG HERE ANY MORE, and the absence is
    # worth a note because there used to be three grants at this point: a
    # blocky-answers group, a ReadWritePaths for blocky, and a supplementary
    # group for Alloy. All three existed to move a file between DynamicUser
    # services that have no build-time uid to grant directly.
    #
    # The journal needs none of it. Alloy already reads it — that is its whole
    # job on this host and it has systemd-journal for that reason — and
    # router-web asks for the same group in web.nix. Both readers were already
    # paying for journal access before this log went anywhere near a file.

  };
}
