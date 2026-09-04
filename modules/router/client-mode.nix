{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
in
{
  config = lib.mkIf cfg.enable {
    # Specialisation for allowing router to act as a client
    specialisation.client.configuration = {
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = lib.mkForce 0;
        "net.ipv6.conf.all.forwarding" = lib.mkForce 0;
      };

      systemd.network.networks = lib.mkForce {
        "10-wan" = {
          matchConfig.Name = cfg.wan;
          linkConfig.RequiredForOnline = "routable";
          networkConfig = {
            DHCP = "yes";
            IPv6AcceptRA = true;
          };
        };
      };

      networking = {
        firewall = {
          filterForward = lib.mkForce false;
          interfaces = lib.mkForce {
            ${cfg.wan}.allowedTCPPorts = [ 22 ];
          };
          extraForwardRules = lib.mkForce "";
        };
        nat.enable = lib.mkForce false;
        nftables.tables = {
          router-filter = lib.mkForce {
            family = "inet";
            content = "";
          };
          router-nat = lib.mkForce {
            family = "ip";
            content = "";
          };
        }
        // lib.optionalAttrs (cfg.meshAddress != null && cfg.meshDNSMappings != { }) {
          router-mesh-dns = lib.mkForce {
            family = "ip";
            content = "";
          };
        };
      };

      # Nothing to be in front of: blocky is off below, so the mesh instance
      # would forward every query into a closed port.
      systemd.services.dnsmasq-mesh = lib.mkIf (cfg.meshAddress != null && cfg.meshDNSMappings != { }) {
        enable = lib.mkForce false;
      };

      services = {
        resolved.enable = lib.mkForce true;
        dnsmasq.enable = lib.mkForce false;
        # blocky binds port 53, which collides with systemd-resolved.
        blocky.enable = lib.mkForce false;
        pppd.enable = lib.mkForce false;
      };
    };
  };
}
