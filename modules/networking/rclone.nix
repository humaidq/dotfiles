{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.rclone;
  inherit (lib)
    mkOption
    types
    mkIf
    mkEnableOption
    ;
in
{
  options.sifr.rclone = {
    enable = mkEnableOption "rclone remote file mounting";

    remote = mkOption {
      type = types.str;
      default = "oreamnos";
      description = "Remote host to connect to";
    };

    remotePath = mkOption {
      type = types.str;
      default = "/mnt/humaid/files";
      description = "Remote path to mount";
    };

    mountPath = mkOption {
      type = types.str;
      default = "files";
      description = "Local mount path relative to home directory";
    };

    sshUser = mkOption {
      type = types.str;
      default = "humaid";
      description = "SSH user for remote connection";
    };

    sshKey = mkOption {
      type = types.str;
      default = "/home/humaid/.ssh/id_ed25519_build";
      description = "SSH key path for authentication";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ rclone ];

    home-manager.users."${vars.user}" = {
      home.file.".config/rclone/rclone.conf".text = ''
        [${cfg.remote}]
        type = sftp
        host = ${cfg.remote}
        user = ${cfg.sshUser}
        key_file = ${cfg.sshKey}
        shell_type = unix
        md5sum_command = md5sum
        sha1sum_command = sha1sum
      '';

      systemd.user.services = {
        "rclone-${cfg.remote}" = {
          Unit = {
            Description = "rclone mount for ${cfg.remote}:${cfg.remotePath}";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
          };

          Service = {
            Type = "notify";
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/${cfg.mountPath}";
            ExecStart = "${pkgs.rclone}/bin/rclone mount ${cfg.remote}:${cfg.remotePath} %h/${cfg.mountPath} --vfs-cache-mode full --vfs-read-ahead 128M";
            ExecStop = "${pkgs.fuse}/bin/fusermount -u %h/${cfg.mountPath}";
            Restart = "on-failure";
            RestartSec = "10s";
            Environment = [
              "PATH=/run/wrappers/bin/:$PATH"
            ];
          };

          Install = {
            WantedBy = [ "default.target" ];
          };
        };
      };
    };
  };
}
