{
  disko.devices =
    let
      mkHDD = device: {
        inherit device;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            dpool = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "dpool";
              };
            };
          };
        };
      };
    in
    {
      disk = {
        # Root pool disks
        ssd0 = {
          device = "/dev/nvme0n1";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                type = "EF00";
                size = "2G";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };
              rpool = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "rpool";
                };
              };
            };
          };
        };
        ssd1 = {
          device = "/dev/nvme1n1";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              rpool = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "rpool";
                };
              };
            };
          };
        };

        # dpool (raidz2) disks
        hdd0 = mkHDD "/dev/disk/by-id/wwn-0x50014ee2c0f5adcb";
        hdd1 = mkHDD "/dev/disk/by-id/wwn-0x50014ee2c0f5af7a";
        hdd2 = mkHDD "/dev/disk/by-id/wwn-0x50014ee2c0f5afee";
        hdd3 = mkHDD "/dev/disk/by-id/wwn-0x50014ee26b9fb952";
        hdd4 = mkHDD "/dev/disk/by-id/wwn-0x50014ee26b9fba84";
      };
      zpool =
        let
          defaultRootOptions = {
            acltype = "posixacl";
            atime = "off";
            canmount = "off";
            xattr = "sa";
            mountpoint = "none";
            "com.sun:auto-snapshot" = "false";
          };
        in
        {
          # Root filesystem pool
          rpool = {
            type = "zpool";
            mode = ""; # stripe
            rootFsOptions = {
              inherit (defaultRootOptions)
                acltype
                atime
                canmount
                xattr
                mountpoint
                "com.sun:auto-snapshot"
                ;
              compression = "zstd";
            };
            options = {
              autotrim = "on";
              ashift = "12";
            };

            datasets = {
              # non-persistent (disposable) root
              "root" = {
                type = "zfs_fs";
                mountpoint = "/";
                postCreateHook = "zfs snapshot rpool/root@blank";
              };

              "nix" = {
                type = "zfs_fs";
                mountpoint = "/nix";
                options = {
                  refreservation = "100G";
                };
              };

              # in case of emergency
              "reserved" = {
                type = "zfs_fs";
                options = {
                  canmount = "off";
                  refreservation = "1G";
                };
              };

              swap = {
                type = "zfs_volume";
                size = "128G";
                options = {
                  volblocksize = "4096";
                  logbias = "throughput";
                  sync = "always";
                  primarycache = "metadata";
                  secondarycache = "none";
                  compression = "zle";
                  "com.sun:auto-snapshot" = "false";
                };
              };

              # persistent data
              "persist" = {
                type = "zfs_fs";
                mountpoint = "/persist";
              };
            };
          };
          # Data pool (RAID)
          dpool = {
            type = "zpool";
            mode = "raidz2";
            options = {
              ashift = "9";
            };
            rootFsOptions = {
              inherit (defaultRootOptions)
                acltype
                atime
                canmount
                xattr
                mountpoint
                "com.sun:auto-snapshot"
                ;
            };
            datasets = {
              "humaid/files" = {
                type = "zfs_fs";
                options = {
                  mountpoint = "/mnt/humaid/files";
                  dedup = "on";
                  compression = "zstd";
                };
              };
              "humaid/borg" = {
                type = "zfs_fs";
                options.mountpoint = "/mnt/humaid/borg";
              };
              "humaid/timemachine" = {
                type = "zfs_fs";
                options.mountpoint = "/mnt/humaid/timemachine";
              };
              "movies" = {
                type = "zfs_fs";
                options.mountpoint = "/mnt/movies";
              };
              # For home-lab services that don't need fast storage
              "services" = {
                type = "zfs_fs";
                mountpoint = "/persist-svc";
              };

              # Really old archives storage
              "archive" = {
                type = "zfs_fs";
                options = {
                  mountpoint = "/mnt/archive";
                  dedup = "on";
                  compression = "zstd";
                };
              };
            };
          };
        };
    };
}
