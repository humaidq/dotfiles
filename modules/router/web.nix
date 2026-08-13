{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.router;
  routerWeb = pkgs.callPackage ./web/package.nix { };

  # The tunnel transports dropped LAN->WAN, read from the same file the nft set
  # is generated from so the peers page cannot drift from the firewall. Only
  # used to flag a port visually, so a line this does not understand is skipped
  # rather than fatal — the generator in ip-blocklist.nix is the authority on
  # that file and already fails the build on a malformed entry.
  suspectPorts =
    let
      lines = lib.splitString "\n" (builtins.readFile ./custom-port-blocklist.txt);
      stripped = map (line: lib.head (lib.splitString "#" line)) lines;
      matches = map (line: builtins.match "[[:space:]]*([0-9]+)[[:space:]]*" line) stripped;
    in
    map lib.head (lib.filter (match: match != null) matches);
in
{
  config = lib.mkIf cfg.enable {
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
          "ROUTER_IP2ASN_FILE=${./ip2asn-combined.tsv}"
          # Both feed the peers page's traffic column: which ports to flag, and
          # which conntrack mark means the qos chain recognised a call.
          "ROUTER_SUSPECT_PORTS=${lib.concatStringsSep "," suspectPorts}"
          "ROUTER_CALL_MARK=${toString cfg.qos.highPriorityMark}"
          "ROUTER_CAPTURE_DIR=%S/router-web/captures"
        ]
        ++ lib.optional (cfg.dhcp.hostsFile != null) "ROUTER_DHCP_HOSTS_FILE=${cfg.dhcp.hostsFile}"
        ++ lib.optional (cfg.meshAddress != null) "ROUTER_LISTEN_MESH=${cfg.meshAddress}:80"
        # Presence alone enables the pool button and badge on the peers page.
        # Set from the same option that creates the nft sets, the drop chains
        # and the `lowtrust` tool, so the page cannot offer an action the
        # firewall does not implement — on a router without the pool the two
        # routes are never registered and the block never renders.
        ++ lib.optional cfg.lowTrust.enable "ROUTER_LOWTRUST=1";
        ExecStart = "${routerWeb}/bin/router-web --root ${routerWeb}/share/router-web --addr :80";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
