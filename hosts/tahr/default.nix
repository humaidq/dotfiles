{
  lib,
  config,
  pkgs,
  self,
  ...
}: {
  imports = [
    self.nixosModules.sifrOS
    (import ./hardware.nix)
  ];

  networking.hostName = "tahr";

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      apps = true;
    };
    v18n.emulation = {
      enable = true;
      systems = ["aarch64-linux"];
    };
    profiles = {
      basePlus = true;
      work = true;
    };
    development.enable = true;

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # Keep system on when lid closed on power
  services.logind.lidSwitchExternalPower = "ignore";
  services.xserver.displayManager.gdm.autoSuspend = false;

  ### All the annoying hardware-specific fixes

  # Annoying Nvidia configurations
  services.xserver.videoDrivers = lib.mkForce ["nvidia"];
  hardware.opengl = {
    enable = true;
    driSupport32Bit = true;
    driSupport = true;
    extraPackages = with pkgs; [vaapiVdpau];
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

  # Fix touchpad click not working
  boot.kernelParams = ["psmouse.synaptics_intertouch=0"];
}
