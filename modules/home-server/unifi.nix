{
  pkgs,
  config,
  lib,
  ...
}:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.unifi = {
      enable = true;
      unifiPackage = pkgs.unifi;
      mongodbPackage = pkgs.mongodb-7_0;
      openFirewall = false;
    };
    networking.firewall = {
      allowedTCPPorts = [
        18080 # unifi.http.port  (device inform)
        18443 # unifi.https.port (controller UI/API)
        18880 # portal.http.port
        18843 # portal.https.port
      ];
      allowedUDPPorts = [
        3478 # unifi.stun.port (usually keep default)
        10001 # device discovery (default)
      ];
    };
    systemd.services.unifi.preStart =
      let
        systemProperties = pkgs.writeText "unifi-system.properties" ''
          # Custom UniFi ports
          unifi.http.port=18080
          unifi.https.port=18443
          portal.http.port=18880
          portal.https.port=18843

          # Leave DB/STUN default unless you *really* need to change them:
          # unifi.db.port=27117
          # unifi.stun.port=3478
        '';
      in
      ''
        install -D -m 600 ${systemProperties} /var/lib/unifi/data/system.properties
      '';
  };

}
