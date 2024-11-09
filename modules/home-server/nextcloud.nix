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
      package = pkgs.nextcloud30;
      hostName = "cloud.alq.ae";
      config.adminpassFile = config.sops.secrets."nextcloud/adminpass".path;

      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps)
          onlyoffice
          integration_paperless
          bookmarks
          ;
      };
    };

    services.onlyoffice = {
      enable = false;
      port = 3015;
      hostname = "onlyoffice.alq.ae";
    };
  };
}
