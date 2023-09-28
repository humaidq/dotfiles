{ config, pkgs, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      memtest86.enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # My configuration specific settings
  hsys = {
    enablei3 = true;
    getDevTools = true;
    laptop = true;
    #virtualisation = true;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  system.stateVersion = "23.0521.11";
}
