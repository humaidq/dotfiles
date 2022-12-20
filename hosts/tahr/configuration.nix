# Work laptop
{ lib, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ../../common
      ../../common/laptop.nix
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
    hostName = "tahr"; # Define your hostname.
    interfaces.wlp0s20f3.useDHCP = true;
  };

  boot.kernelParams = [ "video=efifb:nobgrt" "bgrt_disable" ];

  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];
  hardware.opengl = {
    enable = true;
    driSupport32Bit = true;
    driSupport = true;
    extraPackages = with pkgs; [ vaapiVdpau ];
  };

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    #nvidiaPersistenced = true;
    nvidiaSettings = true;
    prime = {
      #offload.enable = true;
      sync.enable = true;
      intelBusId = lib.mkDefault "PCI:0:2:0";
      nvidiaBusId = lib.mkDefault "PCI:1:0:0";
    };
  };

  # For python server for zephyr tests, and http servers testing
  networking.firewall.allowedTCPPorts = [ 9000 8080 8443 ];

  # My configuration specific settings
  hsys = {
    workProfile = true;

    enableGnome = true;
    enableDwm = true;
    getDevTools = true;
    laptop = true;
    virtualisation = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      auth = true;
      tsKey = "tskey-kKX8n35CNTRL-A76BPGh8jqVkuVFHWA3YJ";
    };
  };
  services.logind.lidSwitchExternalPower = "ignore";

  services.autorandr = {
    enable = true;
    profiles = {
      "default" = {
        fingerprint = {
          "eDP-1-1" = "00ffffffffffff0009e56e0800000000011d0104a52213780358f5a658559d260e505400000001010101010101010101010101010101963b803671383c403020360058c21000001aab2f803671383c403020360058c21000001a000000fe00424f452043510a202020202020000000fe004e5631353646484d2d4e36310a00b9";
        };
        config = {
          "eDP-1-1" = {
            enable = true;
            primary = true;
            mode = "1920x1080";
            rate = "60";
          };
        };
      };
      "work-monitor" = {
        fingerprint = {
          "DP-1" =
            "00ffffffffffff0010ac06424c333535171f0104b55d27783a52f5b04f42ab250f5054a54b00714f81008180a940b300d1c0d100e1c0cd4600a0a0381f4030203a00a1883100001a000000ff00325257535638330a2020202020000000fc0044454c4c20553430323151570a000000fd001856198c49010a2020202020200266020319f14c101f2005140413121103020123090707830100004dd000a0f0703e8030203500a1883100001a565e00a0a0a0295030203500a1883100001a023a801871382d40582c4500a1883100001e011d007251d01e206e285500a1883100001e000000000000000000000000000000000000000000000000000000000000e8701279030001000c4d24500f0014700810788999030128e6120186ff139f002f801f006f083d00020009008b870006ff139f002f801f006f081e00020009000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f90";
          "eDP-1-1" = "00ffffffffffff0009e56e0800000000011d0104a52213780358f5a658559d260e505400000001010101010101010101010101010101963b803671383c403020360058c21000001aab2f803671383c403020360058c21000001a000000fe00424f452043510a202020202020000000fe004e5631353646484d2d4e36310a00b9";
        };
        config = {
          "eDP-1-1".enable = false;
          "DP-1" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "5120x2160";
            rate = "59.98";
          };
        };
      };
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

}

