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
      trustedInterfaces = lib.mkIf cfg.enable [ "sifr0" ];
      allowedUDPPorts = lib.mkIf (cfg.enable && cfg.isLighthouse) [
        4242
      ];
    };
    services.nebula.networks = {
      sifr0 = lib.mkIf cfg.sifr0 {
        enable = true;
        inherit (cfg) isLighthouse;
        isRelay = cfg.isLighthouse;
        tun.device = "sifr0";
        listen.host = "[::]";

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
            respond = true;
          };
          preferred_ranges = [ "10.10.0.0/24" ];
        };
        firewall = {
          outbound = [
            {
              host = "any";
              port = "any";
              proto = "any";
            }
          ];
        };
      };
    };
  };
}
