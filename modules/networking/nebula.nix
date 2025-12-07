{
  pkgs,
  lib,
  config,
  vars,
  ...
}:
let
  cfg = config.sifr.net;

  # Network configuration constants
  nebulaPort = 4242;
  lighthouseIP = "10.10.0.10";
  lighthousePublicEndpoint = "139.84.173.48:4242";

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
  options.sifr.net = {
    sifr0 = lib.mkEnableOption "sifr0 overlay network";
    isLighthouse = lib.mkEnableOption "Lighthouse mode";
    cacheOverPublic = lib.mkOption {
      description = "Use public DNS resolution for cache.huma.id instead of Nebula host entries";
      type = lib.types.bool;
      default = false;
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
    networking.firewall = lib.mkIf cfg.sifr0 {
      trustedInterfaces = [ "sifr0" ];
      allowedUDPPorts = [ nebulaPort ];
    };

    # SSH configuration for Nebula network access only
    services.openssh = lib.mkIf cfg.sifr0 {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
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
      lighthouses = lib.mkIf (!cfg.isLighthouse) [ lighthouseIP ];
      relays = lib.mkIf (!cfg.isLighthouse) [ lighthouseIP ];
      staticHostMap = {
        ${lighthouseIP} = [ lighthousePublicEndpoint ];
      };

      # Network behavior settings
      settings = {
        punchy = {
          punch = true;
          punch_back = true;
          respond = true;
        };
        preferred_ranges = [ "192.168.1.0/24" ];

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
