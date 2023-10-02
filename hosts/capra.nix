{ lib, config, pkgs, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };
  boot.initrd.secrets = {
    "/crypto_keyfile.bin" = null;
  };

  networking.networkmanager.enable = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  virtualisation.docker.enable = true;

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

  system.stateVersion = "23.05";
}
