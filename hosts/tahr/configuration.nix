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
  boot.blacklistedKernelModules = [ "i915" "nouveau" "riafb" "nvidiafb" ];

  #services.xserver.videoDrivers = [ "nvidia" ];
  hardware.opengl = {
    enable = true;
    driSupport32Bit = true;
  };

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    nvidiaPersistenced = true;
    nvidiaSettings = true;
    prime = {
      intelBusId = lib.mkDefault "PCI:0:2:0";
      nvidiaBusId = lib.mkDefault "PCI:1:0:0";
    };
  };
  #hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  #hardware.nvidia.modesetting.enable = true;
  #hardware.opengl.enable = true;

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


  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.11"; # Did you read the comment?

}

