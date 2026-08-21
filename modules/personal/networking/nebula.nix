{
  pkgs,
  lib,
  config,
  vars,
  ...
}:
let
  cfg = config.sifr.personal.net;

  # Network configuration constants
  nebulaPort = 4242;
  # Loopback only; see the stats block below.
  statsPort = 9599;

  # hisn is the sole lighthouse, on 10.10.0.20. It took the role from the old
  # `lighthouse` host on 10.10.0.10 by joining on a NEW overlay address rather
  # than inheriting that one: two lighthouses on two addresses are an ordinary
  # nebula arrangement that nodes register with and query in parallel, whereas
  # two hosts holding certificates for the SAME address is a split — every node
  # settles on whichever answered first, and the ones that chose differently
  # cannot discover each other. Both answered until the fleet had been rebuilt
  # against the two-entry list, and 10.10.0.10 came out afterwards.
  #
  # A node still carrying the old address in its running config is not broken
  # by this — it already knows 10.10.0.20 and registers there. A node that
  # never got the two-entry list is, and has to be rebuilt: nebula refuses to
  # start with am_lighthouse set and lighthouse.hosts non-empty, so hisn never
  # queries and learns endpoints only from the nodes that register with it, and
  # therefore cannot initiate to a host that has not been rebuilt.
  lighthouseIPs = [
    "10.10.0.20"
  ];
  # A static entry is just "this address is reachable at this endpoint" — it
  # does not make the host a lighthouse. Handed to every node, lighthouse
  # included, so a client can reach hisn directly rather than waiting for a
  # lighthouse to have learned about it.
  staticHosts = {
    "10.10.0.20" = [ "45.59.120.67:4242" ];
  };

  # Host mappings
  hostMappings = {
    "10.10.0.11" = [
      "serow"
      "serow.alq"
    ];
    "10.10.0.12" = [
      "oreamnos"
      "oreamnos.alq"
    ]
    ++ lib.optionals (!cfg.cacheOverPublic) vars.homeServerDomains;
    "10.10.0.20" = [
      "hisn"
      "hisn.alq"
    ];
  };

  # Firewall rules
  nebulaFirewallRules = {
    outbound = [
      {
        host = "any";
        port = "any";
        proto = "any";
      }
    ];
    inbound = [
      {
        host = "any";
        port = "any";
        proto = "icmp";
      }
      {
        groups = [ "trusted" ];
        port = "any";
        proto = "any";
      }
      {
        groups = [ "gadgets" ];
        port = "22";
        proto = "any";
      }
    ];
  };
in
{
  options.sifr.personal.net = {
    sifr0 = lib.mkEnableOption "sifr0 overlay network";
    isLighthouse = lib.mkEnableOption "Lighthouse mode";
    cacheOverPublic = lib.mkOption {
      description = "Use public DNS resolution for cache.huma.id instead of Nebula host entries";
      type = lib.types.bool;
      default = false;
    };
    firewallInterfaces = lib.mkOption {
      description = "Interfaces on which to open the Nebula port; null opens it on all interfaces";
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
    };
    node-crt = lib.mkOption {
      description = "Nebula network node certificate";
      type = lib.types.str;
      default = "/etc/nebula/node.crt";
    };
    node-key = lib.mkOption {
      description = "Nebula network node key";
      type = lib.types.str;
      default = "/etc/nebula/node.key";
    };
    ssh-host-key = lib.mkOption {
      description = "Nebula network debug ssh daemon host key";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  config = {
    environment.systemPackages = [ pkgs.nebula ];
    # Firewall configuration
    networking.firewall = lib.mkIf cfg.sifr0 (
      lib.mkMerge [
        {
          trustedInterfaces = [ "sifr0" ];
        }
        (
          if cfg.firewallInterfaces == null then
            {
              allowedUDPPorts = [ nebulaPort ];
            }
          else
            {
              interfaces = lib.genAttrs cfg.firewallInterfaces (_: {
                allowedUDPPorts = [ nebulaPort ];
              });
            }
        )
      ]
    );

    # instance is pinned to the hostname for the same reason the router's
    # uplink scrape does it: Alloy's own exporter components label themselves
    # that way, and a scrape that arrived labelled 127.0.0.1:9599 would be
    # excluded by every panel filtering on instance.
    sifr.personal.o11y.client.extraConfig =
      lib.mkIf (cfg.sifr0 && config.sifr.personal.o11y.client.enable)
        ''
          prometheus.scrape "nebula" {
            targets = [{
              __address__ = "127.0.0.1:${toString statsPort}",
              instance    = "${config.networking.hostName}",
            }]
            metrics_path    = "/metrics"
            scrape_interval = "30s"
            forward_to      = [prometheus.remote_write.default.receiver]
          }
        '';

    # SSH configuration for Nebula network access only
    services.openssh = lib.mkIf cfg.sifr0 {
      enable = true;
      openFirewall = false; # Nebula network access only
    };

    # Host name resolution within Nebula network
    networking.hosts = lib.mkIf cfg.sifr0 hostMappings;

    # Nebula network configuration
    services.nebula.networks.sifr0 = lib.mkIf cfg.sifr0 {
      enable = true;
      inherit (cfg) isLighthouse;
      isRelay = cfg.isLighthouse;
      tun.device = "sifr0";

      # Network listening configuration
      listen = {
        host = "0.0.0.0";
        port = nebulaPort;
      };

      # Certificate and key configuration
      cert = cfg.node-crt;
      key = cfg.node-key;
      ca = ./ca-sifr0.crt;

      # Lighthouse and relay configuration (for non-lighthouse nodes)
      lighthouses = lib.mkIf (!cfg.isLighthouse) lighthouseIPs;
      relays = lib.mkIf (!cfg.isLighthouse) lighthouseIPs;
      # Given to every host, the lighthouse included — nebula ignores its own
      # address here, and handing the map out uniformly keeps the two cases
      # from diverging.
      staticHostMap = staticHosts;

      # Network behavior settings
      settings = {
        punchy = {
          punch = true;
          punch_back = true;
          respond = true;
        };
        preferred_ranges = [
          "10.0.0.0/8"
          "192.168.1.0/24"
        ];

        # Nebula's own view of the mesh, which nothing else can supply: how
        # many tunnels are up, how many handshakes are being retried, what the
        # certificate has left to live. node_exporter sees a sifr0 interface
        # with bytes moving through it and nothing about whether the tunnels
        # carrying them are healthy.
        #
        # Bound to loopback and scraped locally by Alloy, so the listener is
        # not another port to firewall on a public VPS.
        #
        # Enabled for every node rather than the lighthouse alone: the metrics
        # cost is a few dozen series per host, and a mesh problem is usually
        # visible from the side that cannot complete a handshake rather than
        # from the side that never hears about it.
        stats = {
          type = "prometheus";
          listen = "127.0.0.1:${toString statsPort}";
          path = "/metrics";
          # Namespace only. The bridge builds names as
          # <namespace>_<subsystem>_<metric>, and an empty subsystem is
          # dropped, so metrics arrive as nebula_hostmap_main_hosts and the
          # like. A subsystem of "sifr0" would bake the network name into every
          # metric name and make a second network a second set of series to
          # write panels against.
          namespace = "nebula";
          interval = "10s";
        };

        # Optional SSH daemon for debugging
        sshd = lib.mkIf (cfg.ssh-host-key != null) {
          enabled = true;
          listen = "localhost:2202";
          host_key = cfg.ssh-host-key;
          authorized_users = lib.lists.singleton {
            inherit (vars) user;
            inherit (config.users.users.${vars.user}.openssh.authorizedKeys) keys;
          };
        };
      };

      # Nebula firewall rules
      firewall = nebulaFirewallRules;
    };
  };
}
