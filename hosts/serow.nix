{ config, pkgs, ... }: {
  imports = [
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

  # My configuration specific settings
  hsys = {
    enableDwm = true;
    getDevTools = true;
    laptop = true;
    virtualisation = true;
    backups = {
      enable = false;
      repo = "zh2137@zh2137.rsync.net:borg";
    };
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
  };

  system.stateVersion = "23.0521.11";
}
