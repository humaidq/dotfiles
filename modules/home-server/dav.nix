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
    services.radicale = {
      enable = true;
      settings = {
        server = {
          hosts = [
            "0.0.0.0:5232"
            "[::]:5232"
          ];
        };
        auth = {
          type = "htpasswd";
          htpasswd_filename = config.sops.secrets."radicale/htpasswd".path;
          htpasswd_encryption = "plain";
        };
        storage = {
          filesystem_folder = "/var/lib/radicale/collections";
        };
      };
    };

    services.webdav = {
      enable = true;
      user = "humaid";
      environmentFile = config.sops.secrets."webdav/env".path;
      settings = {
        address = "0.0.0.0";
        port = "8477";
        scope = "/mnt/humaid";
        modify = true;
        auth = true;
        permissions = "CRUD";
        users = [
          {
            username = "{env}ENV_USERNAME";
            password = "{env}ENV_PASSWORD";
          }
        ];
      };
    };

    sops.secrets."webdav/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "humaid";
      mode = "600";
    };
    sops.secrets."radicale/htpasswd" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "radicale";
      mode = "600";
    };
  };
}
