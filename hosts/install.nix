{ config, pkgs, lib, ... }: {
  imports = [
    ../common
    ../lib/vmware-guest.nix
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # We have our own module that works with aarch64.
  disabledModules = [ "virtualisation/vmware-guest.nix" ];
  virtualisation.vmware.guest.enable = true;

  # My configuration specific settings
  hsys = {
	enablei3 = true;
    hidpi = true;
    isVM = true;

  };

  system.stateVersion = "23.05";
}
