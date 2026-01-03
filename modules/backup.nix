# This file contains backup settings.
# Based on: https://github.com/Xe/nixos-configs/blob/77dec8742c7605f5bffb02e5939550f8d7564f6c/common/services/backup.nix
{
  config,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr;
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.sifr.backups = {
    enable = mkEnableOption "backups to remote borg repository";
    paths = mkOption {
      description = "Paths to backup";
      type = with types; listOf str;
      default = [
        "/home/${vars.user}/docs"
        "/home/${vars.user}/repos"
        "/home/${vars.user}/inbox"
      ];
    };
    exclude = mkOption {
      description = "Paths to exclude from backups";
      type = with types; listOf str;
      default = [
        "'**/inbox/web'"
        "'**/.cache'"
        "'**/repos/**/result'"
        "'**/repos/**/result/'"
        "'**/.nix-profile'"
        "'**/VirtualBox VMs'"
      ];
    };
    repo = mkOption {
      type = types.str;
      default = "humaid@oreamnos:/mnt/humaid/files/backups/${config.networking.hostName}";
      description = "Repository to backup to";
    };
    startsAt = mkOption {
      type = types.str;
      default = "18:00";
      description = "When the backup starts";
    };
    sshKeyPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to the SSH key for borg";
    };
    borgPassPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to the borg password";
    };
    isRsyncNet = mkEnableOption "rsync.net configurations";
  };

  config = mkIf cfg.backups.enable {
    services.borgbackup.jobs."mainbackup" = {
      archiveBaseName = "${config.networking.hostName}";
      dateFormat = "+%Y-%m-%dT%H:%M:%S";
      inherit (cfg.backups) paths exclude repo;
      encryption = {
        mode = if (cfg.backups.borgPassPath != null) then "repokey-blake2" else "none";
        passCommand = mkIf (cfg.backups.borgPassPath != null) "cat ${cfg.backups.borgPassPath}";
      };
      environment.BORG_RELOCATED_REPO_ACCESS_IS_OK = "yes";
      environment.BORG_RSH = "ssh -i ${cfg.backups.sshKeyPath}";
      environment.BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK = "yes";
      compression = "auto,zstd";
      startAt = cfg.backups.startsAt;
      extraArgs = mkIf cfg.backups.isRsyncNet "--remote-path=borg1"; # rsync.net's executable
    };
  };
}
