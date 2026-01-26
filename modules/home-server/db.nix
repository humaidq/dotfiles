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

    # TODO 25.1 upgrade to v17
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      settings = {
        max_connections = 200;
      };
    };

    # upgrade helper
    environment.systemPackages = [
      (
        let
          newPostgres = pkgs.postgresql_17.withPackages (pp: [
            pp.vectorchord
            pp.pgvector
        ]);
          cfg = config.services.postgresql;
        in
        pkgs.writeScriptBin "upgrade-pg-cluster" ''
          set -eux

          echo SCRIPT DISABLED, ONLY USE DURING UPGRADE
          exit 1

          # XXX it's perhaps advisable to stop all services that depend on postgresql
          systemctl stop postgresql

          export NEWDATA="/var/lib/postgresql/${newPostgres.psqlSchema}"
          export NEWBIN="${newPostgres}/bin"

          export OLDDATA="${cfg.dataDir}"
          export OLDBIN="${cfg.finalPackage}/bin"

          OLD_OPTS="-c shared_preload_libraries=vchord.so"
          NEW_OPTS="-c shared_preload_libraries=vchord.so"

          install -d -m 0700 -o postgres -g postgres "$NEWDATA"
          cd "$NEWDATA"
          sudo -u postgres "$NEWBIN/initdb" -D "$NEWDATA" ${lib.escapeShellArgs cfg.initdbArgs}

          sudo -u postgres "$NEWBIN/pg_upgrade" \
            --old-datadir "$OLDDATA" --new-datadir "$NEWDATA" \
            --old-bindir "$OLDBIN" --new-bindir "$NEWBIN" \
            -o "$OLD_OPTS" -O "$NEW_OPTS" \
            "$@"
        ''
      )
    ];

    services.postgresqlBackup = {
      enable = true;
      location = "/mnt/humaid/files/oreamnos/pgsql-backup";
      compression = "zstd";
    };
  };
}
