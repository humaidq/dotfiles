{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets."nextcloud/adminpass" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "nextcloud";
      mode = "600";
    };
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud29;
      hostName = "cloud.alq.ae";
      config.adminpassFile = config.sops.secrets."nextcloud/adminpass".path;
    };
  };
}
