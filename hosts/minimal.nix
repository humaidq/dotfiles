{ config, pkgs, lib, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };
    efi.canTouchEfiVariables = true;
  };

  # My configuration specific settings
  hsys = {
    enablei3 = true;
    getDevTools = false;
  };
  documentation.enable = lib.mkForce false;

  system.stateVersion = "23.05";
}
