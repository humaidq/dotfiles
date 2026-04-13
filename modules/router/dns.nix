{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;
  blockyCommon = import ./blocky-common.nix;
in

{
  config = lib.mkIf cfg.enable {

    services.dnsmasq = {
      enable = true;
      settings = {
        dhcp-range = [ "${cfg.dhcp.rangeStart},${cfg.dhcp.rangeEnd},${cfg.dhcp.leaseTime}" ];
        dhcp-leasefile = cfg.dhcp.leasesFile;
        interface = [
          cfg.lan0
          "sifr0"
        ];
        domain = cfg.localDomain;
        local = "/${cfg.localDomain}/";
        expand-hosts = true;

        server = [
          "127.0.0.1#1153"
        ];
        no-resolv = true;

        no-hosts = true;

        dhcp-option = [
          "option:router,${cfg.dhcp.routerAddress}"
          "option:dns-server,${cfg.dhcp.dnsServer}"
        ];
      }
      // lib.optionalAttrs (cfg.dhcp.hostsFile != null) {
        dhcp-hostsfile = cfg.dhcp.hostsFile;
      };
    };

    services.resolved.enable = false;

    services.blocky = {
      enable = true;
      settings = lib.recursiveUpdate blockyCommon {
        ports = {
          dns = 1153;
          http = 3333;
          https = 4333;
          tls = 853;
        };
      };
    }; # end blocky

  };
}
