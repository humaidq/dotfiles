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
      #networking.networkmanager.dns = "systemd-resolved";
      #services.resolved = {
      #  enable = true;
      #  dnssec = "allow-downgrade";
      #  #llmnr = "true";
      #  extraConfig = ''
      #    [Resolve]
      #    DNS=1.1.1.1#one.one.one.one
      #    DNSOverTLS=yes
      #    '';
      #  fallbackDns = [ "1.1.1.1#one.one.one.one" ];
      #};
      networking.nameservers = [ "1.1.1.1#one.one.one.one"
      "1.0.0.1#one.one.one.one"];
      networking.extraHosts = builtins.readFile hosts;

      })
  ];

}
