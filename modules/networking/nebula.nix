{ lib, config, ... }:
let
  cfg = config.sifr.net;
in
{
  options.sifr.net = {
    sifr0 = lib.mkEnableOption "sifr0 overlay network";
    isLighthouse = lib.mkEnableOption "Lighthouse mode";
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
  };

  config = {
    networking.firewall = {
      trustedInterfaces = lib.mkIf cfg.sifr0 [ "sifr0" ];
      allowedUDPPorts = lib.mkIf cfg.sifr0  [
        4242
      ];
    };

    services.openssh = lib.mkIf cfg.sifr0 {
      enable = true;

      # Security: do not allow password auth or root login.
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };

      # Do not open firewall rules, nebula can access only.
      openFirewall = false;
    };
    networking.hosts = lib.mkIf cfg.sifr0 {
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
      ];
      "10.10.0.13" = [
        "duisk"
        "duisk.alq"
      ];
    };

    services.nebula.networks = {
      sifr0 = lib.mkIf cfg.sifr0 {
        enable = true;
        inherit (cfg) isLighthouse;
        isRelay = cfg.isLighthouse;
        tun.device = "sifr0";

        listen = {
          host = "[::]";
          port = 4242;
        };

        cert = cfg.node-crt;
        key = cfg.node-key;
        ca = ./ca-sifr0.crt;

        lighthouses = lib.mkIf (!cfg.isLighthouse) [ "10.10.0.10" ];
        relays = lib.mkIf (!cfg.isLighthouse) [ "10.10.0.10" ];
        staticHostMap = {
          "10.10.0.10" = [ "139.84.173.48:4242" ];
        };
        settings = {
          punchy = {
            punch = true;
            punch_back = true;
            respond = true;
          };
          preferred_ranges = [ "192.168.1.0/24" ];
        };
        firewall = {
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
      };
    };
  };
}
