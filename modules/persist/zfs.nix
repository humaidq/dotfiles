{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.persist;
in
{
  config = lib.mkIf (cfg.enable && cfg.zfs.enable) {
    # Reset on every boot
    boot.supportedFilesystems = [ "zfs" ];
    boot.initrd.systemd = {
      enable = true;
      services = {
        "zfs-import-rpool".after = [ "cryptsetup.target" ];
        impermanence-root = {
          wantedBy = [ "initrd.target" ];
          after = [ "zfs-import-rpool.service" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.zfs}/bin/zfs rollback -r ${cfg.zfs.root}@blank";
          };
        };
      };
    };
  };
}
