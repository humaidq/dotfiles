# This file contains backup settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  options.hsys.backups = {
    enable = mkEnableOption "backups to rsync.net";
    paths = mkOption {
      description = "Paths to backup";
      type = with types; listOf str;
      default = [ "/home" ];
    };
    exclude = mkOption {
      description = "Paths to exclude from backups";
      type = with types; listOf str;
      default = [
        "'**/inbox/web'"
        "'**/.cache'"
        "'**/.nix-profile'"
      ];
    };
  };

  config = mkIf cfg.hsys.backups.enable {
    services.borgbackup.jobs."mainbackup" = {
      paths = cfg.backups.paths;
      exclude = cfg.backups.exclude;
      compression = "auto,lzma";
      encryption = {
        mode = "repokey-blake2";
      };

    };

  };

}

