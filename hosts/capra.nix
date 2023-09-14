{ lib, config, pkgs, ... }: {
  imports = [
    ../../common
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot/efi";
  };

  # My configuration specific settings
  hsys = {
    workProfile = true;
    enablei3 = true;
    getDevTools = true;
    laptop = false;

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
