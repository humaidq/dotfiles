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
          "net.ipv4.icmp_echo_ignore_all" = 1;
          # Why isn't this default on NixOS?
          "kernel.dmesg_restrict" = 1;
          "kernel.sysrq" = 0;
        };
        blacklistedKernelModules = [ "cramfs" "freevxfs" "jffs2" "hfs" "hfsplus" ];

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
