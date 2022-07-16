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
    #enableGnome = false;
    #enableMate = true;
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

  networking.firewall.allowedTCPPorts = [ 8008 8009 8010 5000 7236 7250 ];
  networking.firewall.allowedUDPPorts = [ 5000 5353 ];
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 32768;
      to = 61000;
    }
    {
      # miracast
      from = 1024;
      to = 65535;
    }
  ];

  services.autorandr = {
    enable = true;
    profiles = {
      "tv" = {
        fingerprint = {
          eDP1 = "00ffffffffffff0030aeba4000000000001c0104a5221378e238d5975e598e271c5054000000010101010101010101010101010101012e3680a070381f403020350058c210000019582b80a070381f403020350058c2100000190000000f00d10930d10930190a0030e40706000000fe004c503135365746432d535044310072";
          HDMI2 = "00ffffffffffff001e6d010001010101011a010380a05a780aee91a3544c99260f5054a108003140454061407140818001010101010108e80030f2705a80b0588a0040846300001e023a801871382d40582c450040846300001e000000fd003a3e1e883c000a202020202020000000fc004c472054560a20202020202020019f02033cf1545d101f0413051403021220212215015e5f626364293d06c01507500957076e030c001000b83c20008001020304e50e60616566e3060501011d8018711c1620582c250040846300009e662150b051001b304070360040846300001e000000000000000000000000000000000000000000000000000000000000007b";
        };
        config = {
          eDP1.enable = false;
          HDMI2 = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "4096x2160";
            rate = "30";
          };
        };
      };

    };
  };
  #boot.extraModulePackages = with config.boot.kernelPackages; [ xmm7360-pci ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?
}
