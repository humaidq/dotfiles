{ config, pkgs, lib, ... }:
{
  imports =
    [
      ./hardware-configuration.nix
      ../../common
	  ./vmware-guest.nix
    ];

  # Use the systemd-boot EFI boot loader.
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

  networking.hostName = "goral";

  # My configuration specific settings
  hsys = {
	enablei3 = true;
    hidpi = true;
    getDevTools = true;

    isVM = true;

    tailscale = {
      enable = false;
      exitNode = true;
      ssh = true;
    };
  };

  system.stateVersion = "21.11";
}
