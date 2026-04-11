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
        dhcp-range = [ "192.168.1.100,192.168.1.200,12h" ];
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
          "option:router,192.168.1.1"
          "option:dns-server,192.168.1.1"
        ];
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
