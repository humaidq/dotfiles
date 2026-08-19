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

  # The lighthouse is moving to hisn, and it moves to a NEW overlay address
  # rather than inheriting 10.10.0.10. That is what makes the migration safe:
  # two lighthouses on two addresses are an ordinary nebula arrangement, and
  # nodes register with and query both, whereas two hosts holding certificates
  # for the SAME address is a split — every node settles on whichever answered
  # first, and the ones that chose differently cannot discover each other.
  #
  # So the transition has no flag day. hisn joined as a plain client on
  # 10.10.0.20, discoverable through the existing lighthouse with no change on
  # any other node, and is now a lighthouse in its own right alongside the old
  # one. Both answer until every node has been rebuilt against this list; only
  # then does 10.10.0.10 come out.
  #
  # A node reaching a lighthouse it has not been rebuilt for is not a failure
  # mode here — it simply registers with the one it knows. What does not work
  # is the reverse: nebula refuses to start with am_lighthouse set and
  # lighthouse.hosts non-empty, so a lighthouse never queries, and learns
  # endpoints only from the nodes that register with it. hisn therefore cannot
  # initiate to a host that has not yet been rebuilt against this list, which
  # is the reason to roll the fleet promptly rather than leave it half done.
  lighthouseIPs = [
    "10.10.0.10"
    "10.10.0.20"
  ];
  staticHosts = {
    "10.10.0.10" = [ "139.84.173.48:4242" ];
    # Present before hisn is a lighthouse, and deliberately so. A static entry
    # is just "this address is reachable at this endpoint" — it does not make
    # the host a lighthouse. Having it means nodes can reach hisn directly
    # instead of relaying through the far side of the mesh while its services
    # are being moved onto it.
    "10.10.0.20" = [ "45.59.120.67:4242" ];
  };

  # Host mappings
  hostMappings = {
    "10.10.0.10" = [
      "lighthouse"
      "lighthouse.alq"
    ];
    "10.10.0.11" = [
      "serow"
      "serow.alq"
    ];
    "10.10.0.12" = [
      "oreamnos"
      "oreamnos.alq"
    ]
    ++ lib.optionals (!cfg.cacheOverPublic) vars.homeServerDomains;
    "10.10.0.13" = [
      "duisk"
      "duisk.alq"
    ];
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
      # Given to every host, lighthouses included. A lighthouse listing its own
      # address here is what the single-lighthouse config already did, and
      # nebula ignores it; the value of handing the whole map out uniformly is
      # that a client can reach a static host directly during a migration
      # rather than only once some lighthouse has learned about it.
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
