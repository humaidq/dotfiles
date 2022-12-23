# Work laptop
{ lib, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ../../common
    ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      memtest86.enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  networking.hostName = "tahr";

  # Annoying Nvidia configurations
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

  services.logind.lidSwitchExternalPower = "ignore";

  # My configuration specific settings
  hsys = {
    workProfile = true;
    enablei3 = true;
    getDevTools = true;
    laptop = true;
    virtualisation = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      #auth = true;
      #tsKey = "tskey-kKX8n35CNTRL-A76BPGh8jqVkuVFHWA3YJ";
    };
  };

  system.stateVersion = "21.11";
}
