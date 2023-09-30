# This file contains security settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
  hosts = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/StevenBlack/hosts/199df730514da981d1522d4d21a67d1bab6726de/hosts";
    sha256 = "492fe39b260e811ed1c556e6c4abfacf54b2094b8f931cf3c80562505bc04b4c";
  };
in
{
  options.hsys.enableYubikey = mkOption {
    description = "Enables Yubikey support";
    type = types.bool;
    default = false;
  };
  options.hsys.hardenSystem = mkOption {
    description = "Hardens security settings";
    type = types.bool;
    default = true;
  };

  config = mkMerge [
    (mkIf cfg.enableYubikey {
      # Yubikey
      services.udev.packages = with pkgs; [ libu2f-host yubikey-personalization ];
      services.pcscd.enable = true;
    })
    (mkIf (cfg.hardenSystem && !cfg.isVM) {
      # Only enable firewall on non-VMs. VMs rely on host's firewall.
      networking.firewall.enable = true;
      networking.networkmanager.wifi.macAddress = "random";

      # VMs should use host's DNS.
      networking.nameservers = [
        "1.1.1.1#one.one.one.one"
        "1.0.0.1#one.one.one.one"
      ];
    })
    (mkIf cfg.hardenSystem {
      boot.loader.systemd-boot.editor = false;
      programs.gnupg.agent.pinentryFlavor = "qt";

      boot = {
        tmp.cleanOnBoot = true;
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

          # Disable ftrace debugging
          "kernel.ftrace_enabled" = false;

          # Ignore outgoing ICMP redirects (IPv4 only)
          "net.ipv4.conf.all.send_redirects" = false;
          "net.ipv4.conf.default.send_redirects" = false;
        };
        blacklistedKernelModules = [
            "adfs" "af_802154" "affs" "appletalk" "atm" "ax25" "befs" "bfs"
            "btusb" "can" "cifs" "cramfs" "dccp" "decnet" "econet" "efs"
            "erofs" "exofs" "f2fs" "freevxfs" "gfs2" "hfs" "hfsplus" "hpfs"
            "ipx" "jffs2" "jfs" "minix" "n-hdlc" "netrom" "nilfs2" "omfs"
            "p8022" "p8023" "psnap" "qnx4" "qnx6" "rds" "rose" "sctp" "sysv"
            "tipc" "udf" "ufs" "vivid" "x25" "firewire-core" "firewire-sbp2"
            "sbp2" "isdn" "arcnet" "phonet" "wimax" "floppy"

            # no beeping
            "snd_pcsp" "pcspkr"

            # Might use
            "bluetooth"
            "ccid"
          ];
      };
      security = {
        rtkit.enable = true;
        doas = {
          enable = true;
          extraRules = [{
            users = [ "humaid" ];
            persist = true;
            keepEnv = true;
          }];
        };
        sudo.enable = false;
        polkit.enable = true;
        apparmor.enable = true;

        protectKernelImage = true;
        #forcePageTableIsolation = true;
        lockKernelModules = true;
      };

      # Fix set UID issue
      #security.wrappers.slock = {
      #  source = "${pkgs.slock.out}/bin/slock";
      #  setuid = true;
      #  owner = "root";
      #  group = "root";
      #};

      networking.extraHosts = builtins.readFile hosts;
    })
  ];
}
