# This file contains backup settings.
# Based on: https://github.com/Xe/nixos-configs/blob/77dec8742c7605f5bffb02e5939550f8d7564f6c/common/services/backup.nix
{
  config,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr;
  inherit (lib) mkIf mkEnableOption mkOption types;
in {
  options.sifr.backups = {
    enable = mkEnableOption "backups to rsync.net";
    paths = mkOption {
      description = "Paths to backup";
      type = with types; listOf str;
      default = [
        "/home/${vars.user}/docs"
        "/home/${vars.user}/repos"
        "/home/${vars.user}/tii"
        "/home/${vars.user}/projects"
      ];
    };
    exclude = mkOption {
      description = "Paths to exclude from backups";
      type = with types; listOf str;
      default = [
        "'**/inbox/web'"
        "'**/.cache'"
        "'**/.nix-profile'"
        "'**/VirtualBox VMs'"
      ];
    };
    repo = mkOption {
      type = types.str;
      default = "zh2137@zh2137.rsync.net:borg";
      description = "Repository to backup to";
    };
    startsAt = mkOption {
      type = types.str;
      default = "18:00";
      description = "When the backup starts";
    };
    isRsyncNet = mkEnableOption "the backup is to rsync.net";
  };

  config = mkIf cfg.backups.enable {
    services.borgbackup.jobs."mainbackup" = {
      archiveBaseName = "${config.networking.hostName}";
      dateFormat = "+%Y-%b-%d";
      inherit (cfg.backups) paths;
      inherit (cfg.backups) exclude;
      inherit (cfg.backups) repo;
      encryption = {
        mode = "repokey-blake2";
        # TODO use sops-nix
        passCommand = "cat /root/borg_passphrase";
      };
      environment.BORG_RELOCATED_REPO_ACCESS_IS_OK = "yes";
      environment.BORG_RSH = "ssh -i /root/borgbackup_ssh_key";
      compression = "auto,lzma";
      startAt = cfg.backups.startsAt;
      extraArgs = mkIf cfg.backups.isRsyncNet "--remote-path=borg1"; # rsync.net's executable
    };
  };
}
