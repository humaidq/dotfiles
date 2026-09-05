{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.router;
  routerWeb = pkgs.callPackage ./web/package.nix { };

  # name|address|role|pair quads, where pair is "voice" or empty. Flattened
  # into one variable rather than one per anchor because the count is not known
  # at build time, and parsed back with a parser that rejects anything
  # malformed outright — see parseAnchors in web/uplink.go for why a skipped
  # entry would be the worse failure.
  anchorSpec = lib.concatMapStringsSep "," (
    anchor:
    "${anchor.name}|${anchor.address}|${anchor.role}|${lib.optionalString anchor.pairVoice "voice"}"
  ) cfg.uplink.anchors;

  lanHost = lib.head (lib.splitString "/" cfg.lanAddress);

  # The dark-peer collector needs the query log to have something to test a
  # peer's name against, and the mesh listener to publish on — it is scraped
  # over the mesh rather than the LAN for the same reason the peers pages are
  # only there: it says which device is talking to which address.
  darkPeerEnabled = cfg.queryLog.enable && cfg.meshAddress != null;

  # Every mesh endpoint this host knows an address for, taken from the nebula
  # config rather than written out again here.
  #
  # These are the one class of peer guaranteed to match the signature and mean
  # nothing by it: a mesh link is an encrypted tunnel to a bare address that no
  # name ever resolves to, which is the entire finding. Deriving them means a
  # lighthouse that moves — as it did when the role went from 10.10.0.10 to
  # hisn — stops being a false positive on its own, instead of when someone
  # remembers this list exists.
  meshEndpoints = lib.unique (
    map (endpoint: lib.head (lib.splitString ":" endpoint)) (
      lib.flatten (lib.attrValues (config.services.nebula.networks.sifr0.staticHostMap or { }))
    )
  );

  ignoredPeers = lib.unique (meshEndpoints ++ cfg.darkPeer.ignorePeers);
in
{
  options.sifr.router.darkPeer = {
    ignorePeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "139.84.173.48" ];
      description = ''
        Addresses and CIDRs never counted as a device's peer.

        For the endpoints where the signature is correct and the conclusion is
        still wrong. The nebula lighthouse is the case this exists for: it is a
        tunnel by construction, it holds most of the bytes of every host on the
        mesh, and no name is ever resolved to it, so it matches perfectly and
        means nothing.

        A bare address is taken as a host route, so the mask can be left off.
      '';
    };
    exemptClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.40" ];
      description = ''
        LAN addresses never judged.

        For a device that is deliberately and permanently tunnelled — a work
        laptop on a corporate VPN — where the finding is true every day and
        therefore worth nothing. Prefer ignorePeers where the endpoint is the
        known-good part: exempting the device also hides a second tunnel it
        might pick up.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.uplink.enable -> cfg.uplink.anchors != [ ];
        message = ''
          sifr.router.uplink.enable is on with no anchors configured. The PPP
          peer alone cannot measure line quality: it answers from the access
          node's control plane, so its latency and jitter track that node's CPU
          rather than the uplink. Configure at least one "core" anchor.
        '';
      }
      {
        assertion =
          cfg.uplink.enable
          ->
            lib.length (lib.unique (map (anchor: anchor.name) cfg.uplink.anchors))
            == lib.length cfg.uplink.anchors;
        message = "sifr.router.uplink.anchors has duplicate names; each anchor is a separate metric series and a separate row in the history.";
      }
    ];

    # The prober cannot publish through the node_exporter textfile directory
    # the way qos-metrics.nix and host-metrics.nix do: that directory is 0755
    # root root and router-web runs under DynamicUser. It serves /metrics on
    # the LAN listener instead and Alloy scrapes it here.
    #
    # instance is pinned to the hostname to match what Alloy's own exporter
    # components label themselves with. Without it this scrape would arrive
    # labelled with the LAN address and the dashboard's existing
    # instance="$node" filter would exclude every panel built on it.
    sifr.personal.o11y.client.extraConfig = lib.mkIf config.sifr.personal.o11y.client.enable (
      lib.optionalString cfg.uplink.enable ''
        prometheus.scrape "uplink" {
          targets = [{
            __address__ = "${lanHost}:80",
            instance    = "${config.networking.hostName}",
          }]
          metrics_path    = "/metrics"
          scrape_interval = "30s"
          forward_to      = [prometheus.remote_write.default.receiver]
        }
      ''
      # The mesh address, not the LAN one. Same process, different listener:
      # this endpoint names a device and the peer holding its traffic, and
      # the LAN listener deliberately carries no route that can see a device.
      # Alloy runs on this router, so the mesh address is local to it.
      #
      # Scraped a minute apart because that is how often the collector
      # samples — see darkPeerInterval in web/darkpeer.go. A faster scrape
      # would re-read the same snapshot and only make the alert's `for`
      # window count the same minute twice.
      + lib.optionalString darkPeerEnabled ''
        prometheus.scrape "darkpeer" {
          targets = [{
            __address__ = "${cfg.meshAddress}:80",
            instance    = "${config.networking.hostName}",
          }]
          metrics_path    = "/metrics/peers"
          scrape_interval = "60s"
          forward_to      = [prometheus.remote_write.default.receiver]
        }
      ''
    );

    systemd.services.router-web = {
      description = "Router landing page";
      # The mesh address (cfg.meshAddress) lives on sifr0, assigned
      # asynchronously by the nebula@sifr0 instance once it comes up. Ordering
      # after it narrows, but does not eliminate, the race the retry loop in
      # web/main.go's mesh listener is there to absorb — nebula being "started"
      # per systemd does not guarantee the address is assigned yet.
      after = [
        "network-online.target"
      ]
      ++ lib.optional (cfg.meshAddress != null) "nebula@sifr0.service";
      wants = [
        "network-online.target"
      ]
      ++ lib.optional (cfg.meshAddress != null) "nebula@sifr0.service";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        iproute2
        procps
        conntrack-tools
        nftables
        # The peers page's capture button shells out to this. A DynamicUser
        # service builds its PATH from this list alone, so being in
        # environment.systemPackages would not be enough.
        tcpdump
        # journalctl, which answerlog.go follows to name a peer with no PTR.
        # Same reason as tcpdump above: this list is the entire PATH.
        systemd
      ];

      serviceConfig = {
        DynamicUser = true;
        AmbientCapabilities = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
          # Opening a capture socket. tcpdump inherits this service's ambient
          # set, so the capture needs no setuid helper of its own.
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        # Where captures land. DynamicUser puts this under
        # /var/lib/private/router-web and keeps it across restarts, which is
        # what lets a capture interrupted by a restart still be downloaded.
        StateDirectory = "router-web";
        StateDirectoryMode = "0700";
        Environment = [
          "ROUTER_PPP_INTERFACE=${cfg.ppp}"
          "ROUTER_LAN_INTERFACE=${cfg.lan0}"
          "ROUTER_LAN_ADDRESS=${cfg.lanAddress}"
          "ROUTER_LOCAL_DOMAIN=${cfg.localDomain}"
          "ROUTER_DHCP_RANGE_START=${cfg.dhcp.rangeStart}"
          "ROUTER_DHCP_RANGE_END=${cfg.dhcp.rangeEnd}"
          "ROUTER_DHCP_LEASE_TIME=${cfg.dhcp.leaseTime}"
          "ROUTER_DHCP_ROUTER=${cfg.dhcp.routerAddress}"
          "ROUTER_DHCP_DNS=${cfg.dhcp.dnsServer}"
          "ROUTER_DHCP_LEASES_FILE=${cfg.dhcp.leasesFile}"
          "ROUTER_LISTEN_LAN=${lib.head (lib.splitString "/" cfg.lanAddress)}:80"
          "ROUTER_LAN_CIDR=${cfg.lanAddress}"
          # The ASN table behind the peers page's number and organisation
          # columns. GeoLite2's edition replaces the checked-in one when
          # sifr.router.geoip is on: measured against 2895 addresses this
          # network actually resolved, GeoLite2-ASN placed 10 that ip2asn did
          # not — Bytedance, Amazon and Automattic ranges among them — against
          # 2 the other way.
          #
          # The checked-in table stays in the repository regardless, because
          # ip-blocklist.nix expands custom-lowtrust-asns.txt and
          # custom-cdn-quota-asns.txt against it at BUILD time and a sandboxed
          # Nix build cannot read a file a licence key fetches at runtime.
          #
          # That leaves two ASN maps on the router, which is only safe because
          # they agree where it matters: both know all 42 AS numbers those two
          # lists name, and the prefixes they expand to differ by about 2% of
          # addresses. The 3.5% of lookups where they disagree outright are
          # Etisalat's own prefixes — AS8966 against AS5384, an
          # origin-versus-holder split — and neither list names either number.
          #
          # Chosen here rather than overridden from geoip.nix on purpose: a
          # second Environment= line for the same variable is not an override,
          # it is a shadow, and geoip.nix has the comment on how that went.
          "ROUTER_IP2ASN_FILE=${
            if cfg.geoip.enable then "${cfg.geoip.stateDir}/asn.tsv" else "${./ip2asn-combined.tsv}"
          }"
          # Both feed the peers page's traffic column: which ports to flag, and
          # which conntrack mark means the qos chain recognised a call.
          #
          # A path rather than the ports themselves since 2026-09-03: the list
          # is a sops secret, so it cannot be read at eval time any more. Same
          # file the nft set is generated from, so the peers page cannot drift
          # from the firewall. Only used to flag a port visually, so a line the
          # reader does not understand is skipped rather than fatal — the
          # generator in ip-blocklist.nix is the authority on that file and
          # fails nft-blocklists-local on a malformed entry.
          "ROUTER_SUSPECT_PORTS_FILE=${cfg.lists.portBlocklist}"
          "ROUTER_CALL_MARK=${toString cfg.qos.highPriorityMark}"
          "ROUTER_CAPTURE_DIR=%S/router-web/captures"
        ]
        ++ lib.optional (cfg.dhcp.hostsFile != null) "ROUTER_DHCP_HOSTS_FILE=${cfg.dhcp.hostsFile}"
        # Where a peer actually is, as opposed to where its AS is registered.
        # Unset means no country column at all rather than a fallback to the
        # ASN registration, which is the wrong answer geo.go exists to replace.
        # The table watcher picks the file up whenever it appears, so pointing
        # at one the first timer run has yet to write is fine.
        ++ lib.optional cfg.geoip.enable "ROUTER_GEOIP_FILE=${cfg.geoip.stateDir}/country.tsv"
        # The resolver's query log, which names an address that has no PTR.
        # Unset means the peers page shows reverse names only, exactly as it
        # did before this existed.
        #
        # A unit to follow rather than a directory to read since 2026-08-30:
        # the log went back to the journal so the dashboard's DNS panels could
        # have it too. See sifr.router.queryLog in dns.nix for why one log with
        # two readers is the only arrangement that serves both.
        ++ lib.optional cfg.queryLog.enable "ROUTER_ANSWERLOG_UNIT=${cfg.queryLog.unit}"
        # Presence of the file is what puts the access point section on the
        # status page. Unset means no probe socket, no goroutine and no
        # section — the same opt-in idiom as the uplink database below.
        ++ lib.optional (cfg.accessPoints.file != null) "ROUTER_AP_FILE=${cfg.accessPoints.file}"
        # The optical section on the status page. Presence of the path is the
        # opt-in, and the file itself is the second gate: it is written by
        # ont-textfile, which only runs where the o11y client is enabled, and
        # router-web renders no section at all when it is missing. So this can
        # be set on the strength of the ONT being configured without having to
        # restate the metrics-stack condition here.
        #
        # A path to read, not a credential. router-web cannot reach the ONT —
        # see the header of web/ont.go for why that separation is the point.
        ++ lib.optional cfg.ont.enable "ROUTER_ONT_FILE=${cfg.ont.metricsFile}"
        # Presence of the path is what puts the Full Reboot section on the
        # status page. Writing this file is the entirety of what router-web
        # does for the feature: a root path unit watches for it and runs the
        # sequence — see modules/router/fullreboot.nix. Under the state
        # directory because that is the one place a DynamicUser service can
        # write, and it is persisted, so a request cannot be lost.
        ++ lib.optionals cfg.fullReboot.enable [
          "ROUTER_FULL_REBOOT_REQUEST=%S/router-web/full-reboot.request"
          # Read-only here. Written by the root scripts on either side of the
          # reboot; world readable so this DynamicUser service can render the
          # timeline without being able to rewrite what it says happened.
          "ROUTER_FULL_REBOOT_HISTORY=/var/lib/router-fullreboot/history.tsv"
          # While this exists the uplink prober withholds events, because the
          # outage is this router's own doing. Same reasoning as the startup
          # grace it sits beside in web/uplink.go.
          "ROUTER_UPLINK_MAINTENANCE=/var/lib/router-fullreboot/maintenance"
        ]
        ++ lib.optional (cfg.meshAddress != null) "ROUTER_LISTEN_MESH=${cfg.meshAddress}:80"
        # The dark-peer collector's two exception lists. Both are unset when
        # empty rather than passed as an empty string, so the log line the
        # parser writes for an unusable entry can only ever be about something
        # someone actually put here.
        ++ lib.optional (
          darkPeerEnabled && ignoredPeers != [ ]
        ) "ROUTER_DARKPEER_IGNORE=${lib.concatStringsSep "," ignoredPeers}"
        ++ lib.optional (
          darkPeerEnabled && cfg.darkPeer.exemptClients != [ ]
        ) "ROUTER_DARKPEER_EXEMPT=${lib.concatStringsSep "," cfg.darkPeer.exemptClients}"
        # The domains whose presence behind an address makes it unremarkable.
        # Without this the collector falls back to treating any name at all as
        # unremarkable, which is exactly what a fronted tunnel walks through —
        # see web/commondomains.go. Set with the collector rather than behind a
        # flag of its own: a router with the collector and not the list is a
        # shape with no reason to exist.
        ++ lib.optional darkPeerEnabled "ROUTER_COMMON_DOMAINS_FILE=${cfg.lists.dnsCommonDomains}"
        # Presence alone enables the pool button and badge on the peers page.
        # Set from the same option that creates the nft sets, the drop chains
        # and the `lowtrust` tool, so the page cannot offer an action the
        # firewall does not implement — on a router without the pool the two
        # routes are never registered and the block never renders.
        ++ lib.optional cfg.lowTrust.enable "ROUTER_LOWTRUST=1"
        # Presence enables the cooldown banner, the badge on the devices list
        # and the two routes behind them. Set from the same option that creates
        # the table, the chain and the `cooldown` tool, so the page cannot
        # offer a button the firewall does not implement. The ceiling travels
        # with it so an over-long duration is refused in the browser with a
        # sentence rather than as a 500 carrying the tool's stderr.
        ++ lib.optionals cfg.cooldown.enable [
          "ROUTER_COOLDOWN=1"
          "ROUTER_COOLDOWN_MAX_SECONDS=${toString cfg.cooldown.maxSeconds}"
        ]
        # Presence of the database path is what turns probing on: unset means
        # no raw socket, no goroutines, no file, and neither /uplink nor
        # /metrics registered. Under the same StateDirectory as the captures,
        # so the history survives a restart and a redeploy — which is most of
        # the point of keeping it on disk at all.
        ++ lib.optionals cfg.uplink.enable [
          "ROUTER_UPLINK_DB=%S/router-web/uplink.db"
          "ROUTER_UPLINK_ANCHORS=${anchorSpec}"
          "ROUTER_UPLINK_RETENTION_DAYS=${toString cfg.uplink.retentionDays}"
        ];
        ExecStart = "${routerWeb}/bin/router-web --root ${routerWeb}/share/router-web --addr :80";
        Restart = "on-failure";
        RestartSec = "5s";
        # The AP list can hold admin logins, so the secret it comes from may be
        # group-readable rather than world-readable. router-web joins router-ap
        # to read it — the same idiom router-vpn uses to let this DynamicUser
        # service reach a file it has no build-time uid to be granted directly.
        # Harmless when the list carries no logins and the secret is world
        # readable anyway, and merges cleanly with the router-vpn group vpn.nix
        # adds the same way.
        # systemd-journal is the read side of the resolver's query log, which
        # names a peer that has no PTR — see sifr.router.queryLog in dns.nix.
        # The whole journal, not just blocky's: journald has no per-unit
        # access control, so following one unit costs the same group as
        # following all of them. answerlog.go follows exactly one and parses
        # two fields out of it.
        #
        # The static DHCP reservations are a sops secret owned by dnsmasq, and
        # until this group was added router-web could not read a byte of it.
        # That was visible in two places at once: the status page reported
        # "configured" instead of a count of reservations, and the peers pages
        # rendered every reserved device as an em-dash — including the ones
        # whose reservation says `infinite`, which is precisely the setting
        # that stops a device renewing and so keeps it out of the lease file
        # for good. Named rather than given its own group, unlike router-ap:
        # the file already has an owner that must keep reading it, and a file
        # has only one group to give away.
        SupplementaryGroups =
          lib.optional (cfg.accessPoints.file != null) "router-ap"
          ++ lib.optional (cfg.dhcp.hostsFile != null) "dnsmasq"
          ++ lib.optional cfg.queryLog.enable "systemd-journal";
      };
    };

    # The group the access-point secret may be owned by. Created whenever a list
    # is configured so a host can name it as the secret's group; router-web is
    # its only member.
    users.groups.router-ap = lib.mkIf (cfg.accessPoints.file != null) { };
  };
}
