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
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        ExecStart = "${routerWeb}/bin/router-web --root ${routerWeb}/share/router-web --addr :80";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
