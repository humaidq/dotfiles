{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.security;
  hosts = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/StevenBlack/hosts/6b6cba7dc79b459f80ffc44b3dd9973effdbed34/hosts";
    sha256 = "492fe39b260e811ed1c556e6c4abfacf54b2094b8f931cf3c80562505bc04b4c";
  };
  inherit (lib) mkOption types mkMerge mkIf mkDefault;
in {
  options.sifr.security.harden = mkOption {
    description = "Hardens the system settings";
    type = types.bool;
    default = pkgs.stdenv.isLinux;
  };
  options.sifr.security.yubikey = mkOption {
    description = "Enables YubiKey support";
    type = types.bool;
    default = false;
  };
  options.sifr.security.doas = mkOption {
    description = "Replaces sudo with minimal alternative (doas)";
    type = types.bool;
    default = pkgs.stdenv.isLinux;
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
      # Boot and kernel hardening
      boot = {
        # /tmp uses tmpfs and cleans on boot
        tmp.cleanOnBoot = true;
        tmp.useTmpfs = true;

        # Block boot menu editor.
        loader.systemd-boot.editor = mkDefault false;

        kernelParams = [
          # Enable sanity check, redzoning, poisoning.
          "slub_debug=FZP"
          # Page allocator randomisatoin
          "page_alloc.shuffle=1"
          # Reduce boot TTY output
          "quiet"
          "vga=current"
        ];

        kernel.sysctl = {
          "fs.suid_dumpable" = 0;
          "kernel.yama.ptrace_scope" = 1;
          # Why isn't this default on NixOS?
          "kernel.dmesg_restrict" = 1;
          "kernel.sysrq" = 0;
          # Disable broadcast ICMP
          "net.ipv4.icmp_echo_ignore_broadcasts" = true;

          # Enables strict reverse path filtering, and log them
          "net.ipv4.conf.all.log_martians" = true;
          "net.ipv4.conf.all.rp_filter" = "1";
          "net.ipv4.conf.default.log_martians" = true;
          "net.ipv4.conf.default.rp_filter" = "1";
          # Prevent bogus ICMP errors from filling logs
          "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

          # Ignore all ICMP packets
          "net.ipv4.conf.all.accept_redirects" = false;
          "net.ipv4.conf.all.secure_redirects" = false;
          "net.ipv4.conf.default.accept_redirects" = false;
          "net.ipv4.conf.default.secure_redirects" = false;
          "net.ipv6.conf.all.accept_redirects" = false;
          "net.ipv6.conf.default.accept_redirects" = false;

          # hide kptr
          "kernel.kptr_restrict" = 2;

          # Prevent syn flood attack
          "net.ipv4.tcp_syncookies" = 1;
          "net.ipv4.tcp_synack_retries" = 5;

          # Disable bpf() JIT (to eliminate spray attacks)
          "net.core.bpf_jit_enable" = false;

          # TIME-WAIT Assassination fix
          "net.ipv4.tcp_rfc1337" = 1;

          # Disable ftrace debugging
          "kernel.ftrace_enabled" = false;

          # Ignore outgoing ICMP redirects (IPv4 only)
          "net.ipv4.conf.all.send_redirects" = false;
          "net.ipv4.conf.default.send_redirects" = false;

          # Use TCP fast open to speed up some requests
          "net.ipv4.tcp_fastopen" = 3;
        };

        blacklistedKernelModules = [
          "adfs"
          "af_802154"
          "affs"
          "appletalk"
          "atm"
          "ax25"
          "befs"
          "bfs"
          "btusb"
          "can"
          "cifs"
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
          "bluetooth"
          "ccid"
          "wwan"
          "nfc"
        ];
      };

      security = {
        polkit.enable = true;
        rtkit.enable = true;
        apparmor.enable = true;

        protectKernelImage = true;
        forcePageTableIsolation = true;
      };

      # StevenBlack's hosts file.
      networking.extraHosts = builtins.readFile hosts;
    })
  ];
}
