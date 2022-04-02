# This file contains security settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
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
    (mkIf cfg.hardenSystem {
      boot.loader.systemd-boot.editor = false;

      boot = {
        cleanTmpDir = true;
        kernelParams = [
          # Enable sanity check, redzoning, poisoning.
          "slub_debug=FZP"
          # Page allocator randomisatoin
          "page_alloc.shuffle=1"
          # Reduce boot TTY output
          "quiet"
          "vga=current"
        ];
      };
      security = {
        rtkit.enable = true;
        auditd.enable = true;
        doas = {
          enable = true;
          extraRules = [{
            users = [ "humaid" ];
            persist = true;
            keepEnv = true;
          }];
        };
        sudo.enable = false;
        protectKernelImage = true;
        #apparmor.enable = true;
        #forcePageTableIsolation = true;
      };

      networking.firewall.enable = true;
      networking.networkmanager.wifi.macAddress = "random"; #security

      # Force use of DNS over TLS, and all requests must be validated with DNSSEC
      services.resolved.enable = true;
      services.resolved.dnssec = "true";
      services.resolved.extraConfig = "DNSOverTLS=true";
      networking.networkmanager.dns = "systemd-resolved";
      networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];
    })
  ];

}
