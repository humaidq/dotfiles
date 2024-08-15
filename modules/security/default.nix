{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.security;
  inherit (lib) mkOption types mkMerge mkIf mkDefault mkEnableOption;
in {
  options.sifr.security = {
    harden = mkOption {
      description = "Whether to harden the system";
      type = types.bool;
      default = pkgs.stdenv.isLinux;
    };
    yubikey = mkEnableOption "YubiKey support";
    doas = mkEnableOption "OpenBSD's doas utility";
  };

  config = mkMerge [
    (mkIf cfg.doas {
      security.sudo.enable = false;
      security.doas = {
        enable = true;
        extraRules = [
          {
            users = ["${vars.user}"];
            persist = true;
            keepEnv = true;
          }
        ];
      };
    })
    (mkIf cfg.yubikey {
      services.udev.packages = with pkgs; [libu2f-host yubikey-personalization];
      services.pcscd.enable = true;
    })
    (mkIf (cfg.harden && !config.sifr.hardware.vm) {
      # Only enable firewall on non-VMs. VMs rely on host's firewall.
      networking.firewall.enable = true;
      networking.networkmanager.wifi.macAddress = "random";
    })
    (mkIf cfg.harden {
      boot = {
        tmp.cleanOnBoot = true;

        # Block boot menu editor.
        loader.systemd-boot.editor = mkDefault false;

        kernelParams = [
          # Reduce boot TTY output
          "quiet"
          "vga=current"
        ];

        kernel.sysctl = {
          "fs.suid_dumpable" = 0;
          "kernel.dmesg_restrict" = 1;
          "kernel.sysrq" = 0;

          # Enables strict reverse path filtering
          #"net.ipv4.conf.all.rp_filter" = "1";
          #"net.ipv4.conf.default.rp_filter" = "1";

          # Prevent bogus ICMP errors from filling logs
          "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

          # Ignore all ICMP redirects (breaks routers)
          "net.ipv4.conf.all.accept_redirects" = false;
          "net.ipv4.conf.all.secure_redirects" = false;
          "net.ipv4.conf.default.accept_redirects" = false;
          "net.ipv4.conf.default.secure_redirects" = false;
          "net.ipv6.conf.all.accept_redirects" = false;
          "net.ipv6.conf.default.accept_redirects" = false;

          # Prevent syn flood attack
          "net.ipv4.tcp_syncookies" = 1;
          "net.ipv4.tcp_synack_retries" = 5;

          # TIME-WAIT Assassination fix
          "net.ipv4.tcp_rfc1337" = 1;

          # Ignore outgoing ICMP redirects (IPv4 only)
          "net.ipv4.conf.all.send_redirects" = false;
          "net.ipv4.conf.default.send_redirects" = false;

          # Use TCP fast open to speed up some requests
          "net.ipv4.tcp_fastopen" = 3;

          # Enable "TCP Bottleneck Bandwidth and Round-Trip Time Algorithm"
          "net.inet.tcp.functions_default" = "bbr";
          # Use CAKE instead of CoDel
          "net.core.default_qdisc" = "cake";
        };

        kernelModules = ["tcp_bbr"];

        blacklistedKernelModules = [
          "adfs"
          "af_802154"
          "affs"
          "appletalk"
          "atm"
          "ax25"
          "befs"
          "bfs"
          "can"
          "cramfs"
          "dccp"
          "decnet"
          "econet"
          "efs"
          "erofs"
          "exofs"
          "f2fs"
          "freevxfs"
          "gfs2"
          "hfs"
          "hfsplus"
          "hpfs"
          "ipx"
          "jffs2"
          "jfs"
          "minix"
          "n-hdlc"
          "netrom"
          "nilfs2"
          "omfs"
          "p8022"
          "p8023"
          "psnap"
          "qnx4"
          "qnx6"
          "rds"
          "rose"
          "sctp"
          "sysv"
          "tipc"
          "udf"
          "ufs"
          "vivid"
          "x25"
          "firewire-core"
          "firewire-sbp2"
          "sbp2"
          "isdn"
          "arcnet"
          "phonet"
          "wimax"
          "floppy"

          # no beeping
          "snd_pcsp"
          "pcspkr"

          # Might use
          #"bluetooth"
          #"ccid"
          #"wwan"
          #"nfc"
        ];
      };

      security = {
        polkit.enable = true;
        rtkit.enable = true;
        apparmor = {
          enable = true;
          packages = with pkgs; [
            apparmor-utils
            apparmor-profiles
          ];
        };
      };

      networking.stevenblack = {
        enable = true;
        block = ["fakenews" "gambling" "porn"];
      };

      # Set known public keys to prevent MITM
      programs.ssh.knownHosts = {
        "github.com".hostNames = ["github.com"];
        "github.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

        "gitlab.com".hostNames = ["gitlab.com"];
        "gitlab.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";

        "git.sr.ht".hostNames = ["git.sr.ht"];
        "git.sr.ht".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZvRd4EtM7R+IHVMWmDkVU3VLQTSwQDSAvW0t2Tkj60";
      };
    })
  ];
}
