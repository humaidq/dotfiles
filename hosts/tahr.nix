{ lib, config, pkgs, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot/efi";
  };

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

  #services.logind.lidSwitchExternalPower = "ignore";

  # My configuration specific settings
  sifr = {
    workProfile = true;
    enablei3 = true;
    getDevTools = true;
    laptop = true;
    git.sshkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBG6luRkesOBp4w8cMb+d8yUwFZsF02whLR4f3O9+6c humaid.alqassimi+git@tii.ae";

    tailscale = {
      enable = false;
      exitNode = true;
      ssh = true;

      # temp
      #auth = true;
      #tsKey = "tskey-kKX8n35CNTRL-A76BPGh8jqVkuVFHWA3YJ";
    };
  };

  system.stateVersion = "21.11";
}
