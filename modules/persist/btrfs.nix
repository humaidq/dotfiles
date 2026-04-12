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
        after = [ "systemd-udev-settle.service" ];
        before = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          ${pkgs.coreutils}/bin/mkdir -p /btrfs-root
          /bin/mount -t btrfs -o subvolid=5 /dev/disk/by-partlabel/disk-root-root /btrfs-root

          delete_subvolume_recursively() {
            path="$1"
            subvolumes=$(${pkgs.btrfs-progs}/bin/btrfs subvolume list -o "$path" | ${pkgs.coreutils}/bin/cut -f 9- -d ' ')
            for nested in $subvolumes; do
              delete_subvolume_recursively "/btrfs-root/$nested"
            done
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$path"
          }

          if [ -e /btrfs-root/root ]; then
            delete_subvolume_recursively /btrfs-root/root
          fi

          ${pkgs.btrfs-progs}/bin/btrfs subvolume create /btrfs-root/root
          /bin/umount /btrfs-root
        '';
      };
    };
    boot.initrd.kernelModules = [ "btrfs" ];
  };
}
