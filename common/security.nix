# This file contains security settings.
{ config, pkgs, ... }:
{
  # Yubikey
  services.udev.packages = with pkgs; [ libu2f-host yubikey-personalization ];
  services.pcscd.enable = true;

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

  services.resolved.enable = true;
  services.resolved.dnssec = "true";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
}
