{
  lib,
  config,
  pkgs,
  vars,
  ...
}: {
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

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

  services.logind.lidSwitchExternalPower = "ignore";
  services.logind.lidSwitch = "ignore";
  users.users."${vars.user}".openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/iv9RWMN6D9zmEU85XkaU8fAWJreWkv3znan87uqTW"];


  # My configuration specific settings
  sifr = {
    graphics = {
      i3.enable = true;
      gnome.enable = true;
    };

    profiles.basePlus = true;
    development.enable = true;
    security.yubikey = true;
    #git.sshkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBG6luRkesOBp4w8cMb+d8yUwFZsF02whLR4f3O9+6c humaid.alqassimi+git@tii.ae";

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      # temp
      auth = true;
      tsKey = "tskey-auth-kvPeH22CNTRL-xiNd1gFaJf56jwfxa6BVX5wKjEZXmtrL";
    };
  };
}
