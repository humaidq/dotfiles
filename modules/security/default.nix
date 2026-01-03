{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.security;
  inherit (lib)
    mkOption
    types
    mkMerge
    mkIf
    mkEnableOption
    ;
in
{
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
            users = [ "${vars.user}" ];
            persist = true;
            keepEnv = true;
          }
        ];
      };
    })
    (mkIf cfg.yubikey {
      services.udev.packages = with pkgs; [ yubikey-manager ];

      environment.systemPackages = with pkgs; [
        yubioath-flutter
        yubikey-touch-detector
        age-plugin-yubikey
        age
      ];

      programs.yubikey-manager.enable = true;
      programs.yubikey-touch-detector.enable = true;

      services.pcscd.enable = true;
    })
    (mkIf cfg.harden {
      networking.firewall.enable = true;
      networking.networkmanager.wifi.macAddress = "random";
    })
    (mkIf cfg.harden {
      boot = {
        tmp.cleanOnBoot = true;

        # Block boot menu editor.
        #loader.systemd-boot.editor = mkDefault false;

        kernelParams = [
          # Reduce boot TTY output
          "quiet"
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
          #"net.ipv4.conf.all.accept_redirects" = false;
          #"net.ipv4.conf.all.secure_redirects" = false;
          #"net.ipv4.conf.default.accept_redirects" = false;
          #"net.ipv4.conf.default.secure_redirects" = false;
          #"net.ipv6.conf.all.accept_redirects" = false;
          #"net.ipv6.conf.default.accept_redirects" = false;

          # Prevent syn flood attack
          "net.ipv4.tcp_syncookies" = 1;
          "net.ipv4.tcp_synack_retries" = 5;

          # TIME-WAIT Assassination fix
          "net.ipv4.tcp_rfc1337" = 1;

          # Ignore outgoing ICMP redirects (IPv4 only)
          #"net.ipv4.conf.all.send_redirects" = false;
          #"net.ipv4.conf.default.send_redirects" = false;

          # Use TCP fast open to speed up some requests
          "net.ipv4.tcp_fastopen" = 3;

          # Enable "TCP Bottleneck Bandwidth and Round-Trip Time Algorithm"
          "net.inet.tcp.functions_default" = "bbr";
          "net.core.default_qdisc" = "fq"; # cake
        };

        kernelModules = [ "tcp_bbr" ];

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
          "wwan"
          "nfc"
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

      # too many security issues
      #services.avahi.enable = false;

      # don't share hostname
      networking.networkmanager.settings = {
        device = {
          "wifi.scan-rand-mac-address" = true;
        };

        connection = {
          "wifi.cloned-mac-address" = "random";
          #"ethernet.cloned-mac-address" = "random";

          "ipv4.dhcp-send-hostname" = false;
          "ipv6.dhcp-send-hostname" = false;
        };
      };
      services.resolved = {
        llmnr = "false";
        extraConfig = lib.mkAfter ''
          MulticastDNS=no
        '';
      };

      networking.stevenblack = {
        enable = true;
        block = [
          "fakenews"
          "gambling"
          "porn"
        ];
      };
    })
  ];
}
