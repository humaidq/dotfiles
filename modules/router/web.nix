{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.router;
  routerWeb = pkgs.callPackage ./web/package.nix { };
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
      after = [ "network-online.target" ] ++ lib.optional (cfg.meshAddress != null) "nebula@sifr0.service";
      wants = [ "network-online.target" ] ++ lib.optional (cfg.meshAddress != null) "nebula@sifr0.service";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        iproute2
        procps
        conntrack-tools
        nftables
      ];

      serviceConfig = {
        DynamicUser = true;
        AmbientCapabilities = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_ADMIN"
        ];
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
        ]
        ++ lib.optional (cfg.dhcp.hostsFile != null) "ROUTER_DHCP_HOSTS_FILE=${cfg.dhcp.hostsFile}"
        ++ lib.optional (cfg.meshAddress != null) "ROUTER_LISTEN_MESH=${cfg.meshAddress}:80";
        ExecStart = "${routerWeb}/bin/router-web --root ${routerWeb}/share/router-web --addr :80";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
