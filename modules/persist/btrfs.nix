{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.sifr.persist;
  rootDevice = config.fileSystems."/".device;
  rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";
in
{
  config = lib.mkIf (cfg.enable && cfg.btrfs.enable) {
    # Reset on every boot
    boot.supportedFilesystems = [
      "btrfs"
    ];

    boot.initrd.systemd = {
      enable = true;
      storePaths = [ config.boot.initrd.systemd.package.util-linux.mount ];
      services.impermanence-root = {
        wantedBy = [ "initrd.target" ];
        requires = [ rootDeviceUnit ];
        after = [
          "systemd-udev-settle.service"
          rootDeviceUnit
        ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${pkgs.coreutils}/bin/mkdir -p /btrfs-root
          /bin/mount -t btrfs -o subvolid=5 ${lib.escapeShellArg rootDevice} /btrfs-root

          if [ -e /btrfs-root/root ]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete -R /btrfs-root/root
          fi

          ${pkgs.btrfs-progs}/bin/btrfs subvolume create /btrfs-root/root
          /bin/umount /btrfs-root
        '';
      };
    };
    boot.initrd.kernelModules = [ "btrfs" ];
  };
}
