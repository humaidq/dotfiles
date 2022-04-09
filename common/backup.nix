# This file contains backup settings.
# Based on: https://github.com/Xe/nixos-configs/blob/77dec8742c7605f5bffb02e5939550f8d7564f6c/common/services/backup.nix
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
      default = [ "/home" "/root" ];
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
    repo = mkOption {
      type = types.str;
      description = "Repository to backup to";
    };
  };

  config = mkIf cfg.backups.enable {
    services.borgbackup.jobs."mainbackup" = {
      paths = cfg.backups.paths;
      exclude = cfg.backups.exclude;
      repo = cfg.backups.repo;
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /root/borg_passphrase";
      };
      environment.BORG_RELOCATED_REPO_ACCESS_IS_OK = "yes";
      environment.BORG_RSH = "ssh -i /root/borgbackup_ssh_key";
      compression = "auto,lzma";
      startAt = "18:00";
      extraArgs = "--remote-path=borg1"; # rsync.net's executable
    };

  };

}

