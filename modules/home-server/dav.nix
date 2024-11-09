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

    sops.secrets."radicale/htpasswd" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "radicale";
      mode = "600";
    };
  };
}
