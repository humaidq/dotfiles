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

    services.postgresql = {
      enable = true;
      settings = {
        max_connections = 200;
      };
    };

    services.postgresqlBackup = {
      enable = true;
      location = "/mnt/humaid/files/oreamnos/pgsql-backup";
      compression = "zstd";
    };
  };
}
