{
  config,
  lib,
  ...
}:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      port = 3011;
      host = "127.0.0.1";
      mediaLocation = "/persist-svc/immich";
    };
  };
}
