{
  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "2G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "umask=0077"
                  "nofail"
                ];
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };
    }; # end disk

    zpool = {
      rpool = {
        type = "zpool";
        rootFsOptions = {
          mountpoint = "none";
          compression = "lz4";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          "com.sun:auto-snapshot" = "true";
        };
        options = {
          ashift = "12";
          autotrim = "on";
        };
        datasets = {
          "enc" = {
            type = "zfs_fs";
            options = {
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              keylocation = "prompt";
            };
          };
          "enc/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            postCreateHook = "zfs snapshot rpool/enc/root@blank";
          };
          "enc/persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
          };
          "enc/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              refreservation = "10G";
            };
          };
          # in case of emergency
          "enc/reserved" = {
            type = "zfs_fs";
            options = {
              canmount = "off";
              refreservation = "1G";
            };
          };
          "enc/swap" = {
            type = "zfs_volume";
            size = "12G";
            options = {
              volblocksize = "4096";
              logbias = "throughput";
              sync = "disabled";
              primarycache = "metadata";
              secondarycache = "none";
              compression = "off";
              "com.sun:auto-snapshot" = "false";
            };
          };
        };
      };
    };
  };
}
