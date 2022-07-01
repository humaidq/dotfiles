# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../common
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    systemd-boot = {
      enable = true;
      memtest86.enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };
  boot.plymouth.enable = true;
  services.fstrim.enable = true;

  networking = {
    hostName = "serow"; # Define your hostname.
    interfaces.enp0s31f6.useDHCP = true;
    interfaces.wlp0s20f3.useDHCP = true;
  };

  boot.kernelParams = [ "video=efifb:nobgrt" "bgrt_disable" ];

  # My configuration specific settings
  hsys = {
    enableGnome = true;
    enableDwm = true;
    getDevTools = true;
    laptop = true;
    virtualisation = true;
    backups = {
      enable = true;
      repo = "zh2137@zh2137.rsync.net:borg";
    };
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  services.emacs.enable = true;
  services.emacs.install = true;

  networking.firewall.allowedTCPPorts = [ 8008 8009 8010 5000];
  networking.firewall.allowedUDPPorts = [ 5000];
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 32768;
      to = 61000;
    }
  ];
  #boot.extraModulePackages = with config.boot.kernelPackages; [ xmm7360-pci ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?
}
